//! oligarchy-storage-mcp — read-only MCP server for disk/storage capacity.
//!
//! This aspect exists because a full disk is invisible until it starts
//! breaking things that look unrelated. On a Determinate host the first
//! symptom is usually the garbage collector: `determinate-nixd` runs a
//! disk-pressure GC that escalates by orders of magnitude and, when it still
//! cannot reach its target, logs `Relaxing the rubric` and begins deleting
//! paths it would normally protect — including build outputs that were
//! realised seconds ago. What the user sees is a `nix build` result that
//! vanished, or a rebuild that re-downloads what it just fetched. Nothing in
//! that chain mentions free space.
//!
//! So the tools here answer the questions in the order you actually need
//! them: how full is it, what is big, and — the one that is hard to get at
//! any other way — what is *pinning* the store so the GC cannot reclaim it.
//!
//! Read-only by construction, like every aspect — and here that is structural
//! rather than conventional: no binary this aspect can reach is capable of
//! deleting anything. See the note above `impl Server` for why
//! `nix-collect-garbage --dry-run` was tried and then removed.
//!
//! Everything here also has to work as an UNPRIVILEGED user, because that is
//! how the MCP surface runs. Two tools were rewritten for that reason after
//! failing on real hardware: reading the system profile through `nix-env`
//! wants a write lock on `/nix/var/nix/profiles/system.lock` and dies with
//! "Permission denied", so generations are read from the directory directly.

use oligarchy_mcp_core::audit;
use oligarchy_mcp_core::runner::{self, HEAVY_TIMEOUT, QUICK_TIMEOUT};
use oligarchy_mcp_core::runner_mcp;

use std::collections::HashMap;

use rmcp::{
    model::{ServerCapabilities, ServerInfo},
    tool, ServerHandler,
};

const ASPECT: &str = "storage";

/// How many rows a listing tool returns. Enough to see the shape of a disk
/// without burying the caller — the long tail is never what is filling it.
const TOP_N: usize = 25;

#[derive(Debug, Clone, Default)]
struct Server;

// ── argument validation ────────────────────────────────────────────────────

/// Accepts `path` only if it cannot be mistaken for a command-line option.
///
/// This is the load-bearing check in the crate. `runner::run` passes args
/// straight to `execve` with no shell, so there is no quoting or word-splitting
/// to worry about — but there is still **option injection**: a path that begins
/// with `-` is read by the callee as a flag, not a filename. That is merely
/// untidy for `du`, and catastrophic for `find`, which has `-delete` and
/// `-exec`. A read-only aspect that can be talked into `find / -delete` is not
/// a read-only aspect.
///
/// Requiring a leading `/` closes it completely: an absolute path can never be
/// parsed as an option, and every tool here puts the path before any predicate.
fn checked_path(path: &str) -> Result<&str, String> {
    let p = path.trim();
    if p.is_empty() {
        return Err("[error] path is required (an absolute path, e.g. /home)".into());
    }
    if !p.starts_with('/') {
        return Err(format!(
            "[error] path must be absolute (got {p:?}). \
             A relative path or one starting with '-' would be read as a \
             command-line option by the underlying tool, not as a filename."
        ));
    }
    if p.contains('\0') {
        return Err("[error] path contains a NUL byte".into());
    }
    Ok(p)
}

/// Clamps a caller-supplied depth into a range `du` can answer promptly.
/// Depth 0 is a single total; past 4 the output is noise and the walk is slow.
fn checked_depth(depth: u32) -> u32 {
    depth.min(4)
}

/// A floor of 1 MiB. Without one, `find -size +0M` enumerates every file on
/// the machine and the timeout, not the answer, is what the caller gets.
fn checked_min_mb(min_mb: u64) -> u64 {
    min_mb.max(1)
}

// ── formatting ─────────────────────────────────────────────────────────────

fn human(bytes: u64) -> String {
    const GIB: f64 = 1_073_741_824.0;
    const MIB: f64 = 1_048_576.0;
    let b = bytes as f64;
    if b >= GIB {
        format!("{:.1} GiB", b / GIB)
    } else if b >= MIB {
        format!("{:.1} MiB", b / MIB)
    } else {
        format!("{bytes} B")
    }
}

/// Parses `<bytes>\t<path>` or `<bytes><whitespace><path>` lines, as emitted by
/// `du -B1` and by our `find -printf '%s\t%p\n'`. Unparseable lines are
/// dropped rather than failing the call: `du` interleaves "Permission denied"
/// onto the same stream, and one unreadable directory should not cost the
/// caller the whole answer.
fn parse_sized_lines(out: &str) -> Vec<(u64, String)> {
    let mut rows: Vec<(u64, String)> = out
        .lines()
        .filter_map(|line| {
            let (size, rest) = line.split_once(|c: char| c == '\t' || c == ' ')?;
            let size: u64 = size.trim().parse().ok()?;
            let path = rest.trim();
            if path.is_empty() {
                None
            } else {
                Some((size, path.to_string()))
            }
        })
        .collect();
    rows.sort_by(|a, b| b.0.cmp(&a.0));
    rows
}

fn render_rows(rows: &[(u64, String)], limit: usize, empty_note: &str) -> String {
    if rows.is_empty() {
        return empty_note.to_string();
    }
    let mut s = String::new();
    for (size, path) in rows.iter().take(limit) {
        s.push_str(&format!("{:>10}  {}\n", human(*size), path));
    }
    if rows.len() > limit {
        s.push_str(&format!("\n({} more not shown)\n", rows.len() - limit));
    }
    s.trim_end().to_string()
}

// ── system generations, without the lock ───────────────────────────────────

/// Where NixOS keeps the system profile and its generations.
const PROFILES_DIR: &str = "/nix/var/nix/profiles";

/// One entry of the system profile.
#[derive(Debug, PartialEq, Eq)]
struct Generation {
    number: u64,
    target: String,
    current: bool,
}

/// `system-291-link` -> `Some(291)`. Anything else -> `None`.
///
/// The suffix match matters: the profile directory also holds `system`
/// (the current-generation symlink) and other profiles entirely, and a
/// prefix-only test would pull in `system-profile-...` style names.
fn generation_number(name: &str) -> Option<u64> {
    name.strip_prefix("system-")?
        .strip_suffix("-link")?
        .parse()
        .ok()
}

/// Reads the system generations straight off the filesystem.
///
/// Deliberately NOT `nix-env --list-generations`, which takes a write lock on
/// `<profile>.lock` and therefore fails with "Permission denied" for every
/// non-root caller — i.e. always, on this surface. Verified on real hardware.
/// Reading the symlinks needs no lock, no daemon and no privilege.
fn read_generations(dir: &str) -> Vec<Generation> {
    let current = std::fs::read_link(format!("{dir}/system"))
        .ok()
        .and_then(|p| {
            p.file_name()
                .and_then(|n| n.to_str())
                .and_then(generation_number)
        });
    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };
    let mut gens: Vec<Generation> = entries
        .flatten()
        .filter_map(|e| {
            let name = e.file_name();
            let number = generation_number(name.to_str()?)?;
            let target = std::fs::read_link(e.path())
                .map(|t| t.to_string_lossy().into_owned())
                .unwrap_or_else(|_| "(unreadable)".into());
            Some(Generation {
                number,
                target,
                current: Some(number) == current,
            })
        })
        .collect();
    gens.sort_by_key(|g| std::cmp::Reverse(g.number));
    gens
}

fn render_generations(gens: &[Generation], dir: &str) -> String {
    if gens.is_empty() {
        return format!(
            "(no system generations found under {dir})\n\nOn a non-NixOS host \
             this directory does not exist, and that is not an error."
        );
    }
    let mut s = format!(
        "{} system generation(s) on disk. Each pins its entire closure; \
         `sudo nix-collect-garbage --delete-older-than 30d` is the usual way \
         to reduce them.\n\n",
        gens.len()
    );
    for g in gens {
        s.push_str(&format!(
            "{:>6}{}  {}\n",
            g.number,
            if g.current { " (current)" } else { "         " },
            g.target
        ));
    }
    s.trim_end().to_string()
}

// ── nothing here can delete ────────────────────────────────────────────────
//
// This aspect deliberately reaches NO binary that is capable of destroying
// anything. An earlier draft carried `nix-collect-garbage --dry-run` behind a
// hard-coded-argument guard, on the theory that a preview is read-only. Two
// things killed it, and the second is the important one:
//
//   1. It does not work. Run by an unprivileged user — which is how the MCP
//      surface always runs — it operates on that user's own profiles, finds
//      nothing, and exits 0 having printed nothing at all. Verified on real
//      hardware. A tool that silently returns nothing is worse than absent.
//
//   2. Keeping it made the read-only property a CONVENTION (one constant and
//      one assertion stand between the aspect and `nix-collect-garbage` with
//      no arguments, which deletes) rather than a STRUCTURAL fact. Removing it
//      means no reachable binary can delete, so there is no guard to get
//      wrong in a later edit.
//
// A real GC preview needs root. That belongs in the user's hands
// (`sudo nix-collect-garbage --dry-run`), not behind a read-only agent
// surface. `nix_gc_roots` plus `nix_closure_size` answer the question that
// actually matters — what is PINNING the store — and both work unprivileged.

#[tool(tool_box)]
impl Server {
    #[tool(
        description = "Filesystem capacity: size, used, available and percentage \
                       per mounted filesystem (df). Start here — every other \
                       tool in this aspect is a follow-up to a full disk."
    )]
    fn disk_usage(&self) -> String {
        audit::tool(ASPECT, "disk_usage", "");
        // -x excludes the pseudo-filesystems (tmpfs, devtmpfs) that otherwise
        // pad the table with rows nobody can free space on.
        runner::run(
            ASPECT,
            "df",
            &["-h", "-x", "tmpfs", "-x", "devtmpfs", "-x", "efivarfs"],
            QUICK_TIMEOUT,
        )
        .unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(
        description = "Largest directories under an absolute path, biggest first. \
                       `depth` is clamped to 4. Stays on one filesystem, so \
                       pointing it at / will not descend into other mounts. \
                       This is the workhorse for 'where did the space go'."
    )]
    fn directory_sizes(&self, #[tool(param)] path: String, #[tool(param)] depth: u32) -> String {
        audit::tool(ASPECT, "directory_sizes", &format!("{path} depth={depth}"));
        let path = match checked_path(&path) {
            Ok(p) => p,
            Err(e) => return e,
        };
        let depth = checked_depth(depth);
        let depth_arg = format!("--max-depth={depth}");
        // -B1 so the sizes are raw bytes and we can sort numerically here
        // rather than depending on `sort -h` through a shell we do not have.
        match runner::run(
            ASPECT,
            "du",
            &["-x", &depth_arg, "-B1", path],
            HEAVY_TIMEOUT,
        ) {
            Ok(out) => render_rows(&parse_sized_lines(&out), TOP_N, "(nothing measurable)"),
            Err(e) => format!("[error] {e}"),
        }
    }

    #[tool(
        description = "Largest individual files under an absolute path, biggest \
                       first. `min_mb` floors at 1. Finds the stray ISOs, disk \
                       images and archives that directory totals hide."
    )]
    fn largest_files(&self, #[tool(param)] path: String, #[tool(param)] min_mb: u64) -> String {
        audit::tool(ASPECT, "largest_files", &format!("{path} min={min_mb}M"));
        let path = match checked_path(&path) {
            Ok(p) => p,
            Err(e) => return e,
        };
        let min_mb = checked_min_mb(min_mb);
        let size_arg = format!("+{min_mb}M");
        // The path is first, so nothing after it can be reinterpreted; -xdev
        // keeps the walk on one filesystem the way `du -x` does.
        match runner::run(
            ASPECT,
            "find",
            &[
                path, "-xdev", "-type", "f", "-size", &size_arg, "-printf", "%s\t%p\n",
            ],
            HEAVY_TIMEOUT,
        ) {
            Ok(out) => render_rows(
                &parse_sized_lines(&out),
                TOP_N,
                &format!("(no files over {min_mb} MiB under {path})"),
            ),
            Err(e) => format!("[error] {e}"),
        }
    }

    #[tool(
        description = "Files that appear more than once under a path with the \
                       same name and size — likely duplicate copies of the same \
                       image or archive. Reports wasted bytes per group."
    )]
    fn duplicate_large_files(
        &self,
        #[tool(param)] path: String,
        #[tool(param)] min_mb: u64,
    ) -> String {
        audit::tool(
            ASPECT,
            "duplicate_large_files",
            &format!("{path} min={min_mb}M"),
        );
        let path = match checked_path(&path) {
            Ok(p) => p,
            Err(e) => return e,
        };
        let min_mb = checked_min_mb(min_mb);
        let size_arg = format!("+{min_mb}M");
        let out = match runner::run(
            ASPECT,
            "find",
            &[
                path, "-xdev", "-type", "f", "-size", &size_arg, "-printf", "%s\t%p\n",
            ],
            HEAVY_TIMEOUT,
        ) {
            Ok(o) => o,
            Err(e) => return format!("[error] {e}"),
        };
        render_duplicates(&parse_sized_lines(&out), min_mb)
    }

    #[tool(
        description = "Every garbage-collector root, i.e. what is PINNING the Nix \
                       store so it cannot be reclaimed. Usually the answer when \
                       the store is large but `nix-collect-garbage` frees \
                       nothing: stray `result` symlinks in project directories \
                       each pin a whole closure."
    )]
    fn nix_gc_roots(&self) -> String {
        audit::tool(ASPECT, "nix_gc_roots", "");
        match runner::run(
            ASPECT,
            "nix-store",
            &["--gc", "--print-roots"],
            HEAVY_TIMEOUT,
        ) {
            Ok(out) => render_gc_roots(&out),
            Err(e) => format!("[error] {e}"),
        }
    }

    #[tool(
        description = "Closure size of a /nix/store path — how much disk a single \
                       gcroot is actually holding down. Pair with nix_gc_roots to \
                       find which root is expensive."
    )]
    fn nix_closure_size(&self, #[tool(param)] store_path: String) -> String {
        audit::tool(ASPECT, "nix_closure_size", &store_path);
        let p = match checked_path(&store_path) {
            Ok(p) => p,
            Err(e) => return e,
        };
        if !p.starts_with("/nix/store/") {
            return format!("[error] not a store path: {p} (expected /nix/store/...)");
        }
        runner::run(ASPECT, "nix", &["path-info", "-S", "-h", p], HEAVY_TIMEOUT)
            .unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(
        description = "NixOS system generations still on disk, newest first. \
                       Each generation pins its whole closure, so old ones are \
                       a common source of reclaimable space."
    )]
    fn nix_generations(&self) -> String {
        audit::tool(ASPECT, "nix_generations", "");
        render_generations(&read_generations(PROFILES_DIR), PROFILES_DIR)
    }

    #[tool(
        description = "Recent garbage-collector activity from determinate-nixd. \
                       Shows disk-pressure GC escalation and the 'Relaxing the \
                       rubric' warning that means the GC could not reach its \
                       target and started evicting paths it would normally keep \
                       — including freshly built outputs."
    )]
    fn gc_pressure(&self) -> String {
        audit::tool(ASPECT, "gc_pressure", "");
        match runner::run(
            ASPECT,
            "journalctl",
            &[
                "--no-pager",
                "-b",
                "-t",
                "determinate-nixd",
                "-o",
                "short-iso",
                "-n",
                "400",
            ],
            QUICK_TIMEOUT,
        ) {
            Ok(out) => render_gc_pressure(&out),
            Err(e) => format!(
                "[error] {e}\n\n(No determinate-nixd journal. On a host using \
                 upstream Nix rather than Determinate Nix there is no \
                 disk-pressure GC, and this tool has nothing to report.)"
            ),
        }
    }
}

// ── pure helpers, unit-tested below ────────────────────────────────────────

/// Groups files by `(basename, size)` and reports only groups with more than
/// one member. Same name AND same byte count is a strong duplicate signal and
/// costs no hashing; it is deliberately a heuristic, and says so.
fn render_duplicates(rows: &[(u64, String)], min_mb: u64) -> String {
    let mut groups: HashMap<(String, u64), Vec<String>> = HashMap::new();
    for (size, path) in rows {
        let base = path.rsplit('/').next().unwrap_or(path).to_string();
        groups.entry((base, *size)).or_default().push(path.clone());
    }
    let mut dupes: Vec<((String, u64), Vec<String>)> =
        groups.into_iter().filter(|(_, v)| v.len() > 1).collect();
    if dupes.is_empty() {
        return format!("(no duplicate files over {min_mb} MiB found)");
    }
    // Rank by RECLAIMABLE bytes — every copy after the first.
    dupes.sort_by_key(|((_, size), v)| std::cmp::Reverse(size * (v.len() as u64 - 1)));

    let mut total_waste: u64 = 0;
    let mut s = String::new();
    for ((base, size), mut paths) in dupes.into_iter().take(TOP_N) {
        let waste = size * (paths.len() as u64 - 1);
        total_waste += waste;
        paths.sort();
        s.push_str(&format!(
            "{} — {} copies x {} (reclaimable {})\n",
            base,
            paths.len(),
            human(size),
            human(waste)
        ));
        for p in paths {
            s.push_str(&format!("    {p}\n"));
        }
        s.push('\n');
    }
    s.push_str(&format!(
        "Reclaimable if each group is reduced to one copy: {}\n\
         (Heuristic: matched on identical filename AND identical byte size, \
         not on content hash.)",
        human(total_waste)
    ));
    s
}

/// Summarises `nix-store --gc --print-roots`.
///
/// The raw output is dominated by per-process roots (`/proc/<pid>/...`), which
/// are transient and never actionable — a running program holding its own
/// closure. Those are counted and set aside so the persistent roots, which are
/// the ones a user can actually do something about, are visible.
fn render_gc_roots(out: &str) -> String {
    let mut transient = 0usize;
    let mut persistent: Vec<(&str, &str)> = Vec::new();
    for line in out.lines() {
        let Some((root, target)) = line.split_once(" -> ") else {
            continue;
        };
        let root = root.trim();
        let target = target.trim();
        if root.starts_with("/proc/") || root.contains("{censored}") || root.starts_with("{memory") {
            transient += 1;
        } else {
            persistent.push((root, target));
        }
    }
    if persistent.is_empty() && transient == 0 {
        return "(no gcroots reported)".into();
    }
    let profiles = persistent
        .iter()
        .filter(|(r, _)| r.starts_with("/nix/var/nix/profiles"))
        .count();
    let results = persistent
        .iter()
        .filter(|(r, _)| {
            r.rsplit('/')
                .next()
                .is_some_and(|n| n.starts_with("result"))
        })
        .count();

    let mut s = String::new();
    s.push_str(&format!(
        "{} persistent gcroot(s); {} transient (/proc, ignored).\n\
         Of the persistent ones: {} are profile generations, {} are 'result' \
         symlinks from a `nix build`.\n\n\
         Each root pins its ENTIRE closure. A stray `result` link in a project \
         directory is the usual reason a large store will not shrink; check one \
         with nix_closure_size before removing it.\n\n",
        persistent.len(),
        transient,
        profiles,
        results
    ));
    persistent.sort_by_key(|(r, _)| *r);
    for (root, target) in persistent.iter().take(60) {
        s.push_str(&format!("{root}\n    -> {target}\n"));
    }
    if persistent.len() > 60 {
        s.push_str(&format!("\n({} more not shown)\n", persistent.len() - 60));
    }
    s.trim_end().to_string()
}

/// Extracts the GC lines that mean something from a determinate-nixd journal.
///
/// The escalation ladder (`Garbage collected N bytes`, N climbing by powers of
/// ten) is only interesting in aggregate; the `Relaxing the rubric` warning is
/// the finding, because it means the collector exhausted everything it was
/// willing to delete and started in on what it was not.
fn render_gc_pressure(out: &str) -> String {
    let mut collected: Vec<&str> = Vec::new();
    let mut relaxed: Vec<&str> = Vec::new();
    for line in out.lines() {
        if line.contains("Garbage collected") {
            collected.push(line.trim());
        } else if line.contains("Relaxing the rubric") {
            relaxed.push(line.trim());
        }
    }
    if collected.is_empty() && relaxed.is_empty() {
        return "No garbage-collection activity in the current boot's journal. \
                The collector is not under disk pressure."
            .into();
    }
    let mut s = String::new();
    s.push_str(&format!(
        "{} collection event(s) this boot; {} 'Relaxing the rubric' warning(s).\n\n",
        collected.len(),
        relaxed.len()
    ));
    if !relaxed.is_empty() {
        s.push_str(
            "WARNING: 'Relaxing the rubric' means the GC could not free enough \
             to hit its target and began deleting paths it would normally \
             protect. On a full disk this silently removes freshly built store \
             paths that have no gcroot — a `nix build --no-link` result can \
             disappear within minutes. Free space, or hold builds with an \
             explicit --out-link.\n\n",
        );
        for l in relaxed.iter().take(5) {
            s.push_str(&format!("{l}\n"));
        }
        s.push('\n');
    }
    s.push_str("Most recent collection events:\n");
    for l in collected.iter().rev().take(12) {
        s.push_str(&format!("{l}\n"));
    }
    s.trim_end().to_string()
}

#[tool(tool_box)]
impl ServerHandler for Server {
    fn get_info(&self) -> ServerInfo {
        ServerInfo {
            instructions: Some(
                "Oligarchy storage aspect — disk capacity, what is consuming it, \
                 and what is pinning the Nix store against garbage collection \
                 (read-only)."
                    .into(),
            ),
            capabilities: ServerCapabilities::builder().enable_tools().build(),
            ..Default::default()
        }
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt().init();
    tracing::info!(aspect = ASPECT, "starting");
    runner_mcp::serve(Server::default()).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn aspect_name_is_storage() {
        assert_eq!(ASPECT, "storage");
    }

    #[test]
    fn a_generation_link_name_is_parsed_and_nothing_else_is() {
        assert_eq!(generation_number("system-291-link"), Some(291));
        assert_eq!(generation_number("system-1-link"), Some(1));
        // The current-generation symlink and foreign profiles must not be
        // counted as generations.
        for other in ["system", "system-link", "home-manager-3-link", "system-x-link", ""] {
            assert_eq!(generation_number(other), None, "{other:?}");
        }
    }

    #[test]
    fn generations_render_newest_first_and_mark_the_current_one() {
        let gens = vec![
            Generation { number: 291, target: "/nix/store/aaa-sys".into(), current: true },
            Generation { number: 290, target: "/nix/store/bbb-sys".into(), current: false },
        ];
        let s = render_generations(&gens, "/nix/var/nix/profiles");
        assert!(s.contains("2 system generation(s)"), "{s}");
        assert!(s.contains("291 (current)"), "{s}");
        assert!(s.find("291").unwrap() < s.find("290").unwrap(), "newest first");
    }

    #[test]
    fn a_host_with_no_system_profile_is_not_an_error() {
        // A non-NixOS machine, or a container. Must read as "nothing here",
        // never as a failure.
        let s = render_generations(&[], "/nix/var/nix/profiles");
        assert!(s.contains("no system generations"), "{s}");
        assert!(!s.contains("[error]"), "{s}");
    }

    #[test]
    fn reading_a_missing_profile_dir_yields_no_generations_rather_than_panicking() {
        assert!(read_generations("/nonexistent/profiles/dir").is_empty());
    }

    #[test]
    fn a_relative_path_is_refused_because_it_could_be_an_option() {
        // The whole point: `find` reads a leading '-' as a predicate, and its
        // predicates include -delete.
        for bad in ["-delete", "--max-depth=9", "relative/dir", "", "  "] {
            assert!(
                checked_path(bad).is_err(),
                "{bad:?} should have been refused"
            );
        }
        assert_eq!(checked_path("/home/asher").unwrap(), "/home/asher");
        assert_eq!(checked_path("  /nix/store  ").unwrap(), "/nix/store");
    }

    #[test]
    fn bounds_are_clamped_not_trusted() {
        assert_eq!(checked_depth(99), 4);
        assert_eq!(checked_depth(2), 2);
        // A zero floor would enumerate every file on the disk.
        assert_eq!(checked_min_mb(0), 1);
        assert_eq!(checked_min_mb(500), 500);
    }

    #[test]
    fn du_output_is_parsed_and_sorted_biggest_first() {
        // Real `du -B1` output shape, deliberately out of order, with a
        // permission-denied line interleaved the way du actually emits them.
        let out = "1073741824\t/home/a\n\
                   du: cannot read directory '/home/b': Permission denied\n\
                   5368709120\t/home/c\n\
                   2097152\t/home/d\n";
        let rows = parse_sized_lines(out);
        assert_eq!(rows.len(), 3, "the noise line should be dropped, not fatal");
        assert_eq!(rows[0], (5_368_709_120, "/home/c".to_string()));
        assert_eq!(rows[1], (1_073_741_824, "/home/a".to_string()));
    }

    #[test]
    fn sizes_render_in_the_unit_a_human_would_use() {
        assert_eq!(human(5_368_709_120), "5.0 GiB");
        assert_eq!(human(2_097_152), "2.0 MiB");
        assert_eq!(human(512), "512 B");
    }

    #[test]
    fn duplicates_are_grouped_by_name_and_size_and_ranked_by_waste() {
        let rows = vec![
            (9_000_000_000, "/home/a/img.raw".to_string()),
            (9_000_000_000, "/home/b/img.raw".to_string()),
            (9_000_000_000, "/home/c/img.raw".to_string()),
            (1_000_000_000, "/home/a/other.bin".to_string()),
            (1_000_000_000, "/home/b/other.bin".to_string()),
            (5_000_000_000, "/home/a/unique.bin".to_string()),
        ];
        let s = render_duplicates(&rows, 100);
        assert!(s.contains("img.raw — 3 copies"), "{s}");
        assert!(s.contains("other.bin — 2 copies"), "{s}");
        assert!(!s.contains("unique.bin"), "a single copy is not a duplicate");
        // img.raw wastes 2x9GB, other.bin 1x1GB — img.raw must rank first.
        let img = s.find("img.raw").unwrap();
        let other = s.find("other.bin").unwrap();
        assert!(img < other, "groups must rank by reclaimable bytes");
    }

    #[test]
    fn a_file_present_once_is_never_called_a_duplicate() {
        let rows = vec![(9_000_000_000, "/home/a/img.raw".to_string())];
        assert!(render_duplicates(&rows, 100).contains("no duplicate"));
    }

    #[test]
    fn same_name_different_size_is_not_a_duplicate() {
        // Two builds of the same image are NOT interchangeable copies.
        let rows = vec![
            (9_000_000_000, "/home/a/img.raw".to_string()),
            (8_000_000_000, "/home/b/img.raw".to_string()),
        ];
        assert!(render_duplicates(&rows, 100).contains("no duplicate"));
    }

    #[test]
    fn gc_roots_separate_the_actionable_from_the_transient() {
        let out = "/proc/1234/cwd -> /nix/store/aaa-thing\n\
                   /proc/9/environ -> /nix/store/bbb-thing\n\
                   /home/u/project/result -> /nix/store/ccc-image\n\
                   /nix/var/nix/profiles/system-1-link -> /nix/store/ddd-system\n";
        let s = render_gc_roots(out);
        assert!(s.contains("2 persistent gcroot(s); 2 transient"), "{s}");
        assert!(s.contains("1 are profile generations"), "{s}");
        assert!(s.contains("1 are 'result' symlinks"), "{s}");
        // The actionable root must be named; the /proc ones must not be.
        assert!(s.contains("/home/u/project/result"), "{s}");
        assert!(!s.contains("/proc/1234"), "{s}");
    }

    #[test]
    fn an_empty_gc_root_listing_does_not_claim_anything() {
        assert!(render_gc_roots("").contains("no gcroots reported"));
    }

    #[test]
    fn relaxing_the_rubric_is_surfaced_as_the_finding() {
        let out = "2026-08-27T20:03:50 h determinate-nixd[1]: INFO gc: Garbage collected 1000000000 bytes\n\
                   2026-08-27T20:04:03 h determinate-nixd[1]: WARN gc: Rubric called to free more bytes, but the GC ran out of bytes to free. Relaxing the rubric.\n";
        let s = render_gc_pressure(out);
        assert!(s.contains("1 collection event(s)"), "{s}");
        assert!(s.contains("1 'Relaxing the rubric' warning(s)"), "{s}");
        assert!(s.contains("WARNING:"), "the warning must be prominent: {s}");
    }

    #[test]
    fn a_quiet_collector_is_reported_as_quiet_not_as_an_error() {
        // A host that is not under disk pressure is the healthy case and must
        // not read like a failure.
        let s = render_gc_pressure("some unrelated determinate-nixd chatter\n");
        assert!(s.contains("not under disk pressure"), "{s}");
    }

    #[test]
    fn a_store_path_is_required_for_closure_size() {
        // Guard the /nix/store prefix check that keeps this from being a
        // general-purpose path prober.
        assert!(checked_path("/etc/passwd").is_ok());
        assert!(!"/etc/passwd".starts_with("/nix/store/"));
    }
}

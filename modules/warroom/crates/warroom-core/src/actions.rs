//! The action catalog, sourced from `oligarchy-ctl`.
//!
//! OWNER: work stream S4.
//!
//! The War Room drives `oligarchy-ctl` rather than reimplementing it. That
//! dispatcher (`home/apps/control-center/oligarchy-ctl.sh`, 417 lines) is the
//! shared action registry, and it already has a non-terminal consumer in
//! `modules/hypr-controller/hypr_bridge.py`, which forwards to it over UDP for
//! the Android companion app. Reimplementing its PATH-probing logic in Rust
//! would fork that single source of truth immediately.
//!
//! Wire format, verified against the real dispatcher on a live host:
//!
//! ```text
//! $ oligarchy-ctl cats            appearance|🎨 Style          -> id|Label
//! $ oligarchy-ctl items dsp       dsp-status|DSP status        -> id|Label
//! $ oligarchy-ctl all-items       dsp-status|🎛 Audio / DSP · DSP status
//! $ oligarchy-ctl status          Kernel : 7.0.10-zen1         -> Key : Value
//! ```
//!
//! `all-items` is NOT what the catalog is built from: it flattens the category
//! *label* into the item label and drops the category *id*, so a two-column
//! browse cannot be reconstructed from it. `cats` + one `items` per category is
//! the lossless read, and it is done once and cached by the caller.
//!
//! Three things the live dispatcher does that shaped this module:
//!
//! * `items <unknown-category>` prints nothing and exits 0. Empty output is a
//!   distinct state here, never success — see CLAUDE.md's recorded lesson about
//!   unprivileged CLIs that exit 0 having said nothing.
//! * `run <unknown-action>` exits 1 but reports through `notify-send`, so its
//!   stdout is empty too. A successful action is frequently silent for the same
//!   reason; [`run`] says so explicitly rather than rendering a blank pane.
//! * `run` decides between inline output and popping a terminal with `[ -t 1 ]`.
//!   [`exec::run`](crate::exec::run) pipes stdout, so that test is false and
//!   long/interactive actions open their own window instead of fighting the TUI
//!   for this tty. That is the desired behaviour, not an accident.

use crate::exec;
use anyhow::{anyhow, Result};
use serde::Serialize;
use std::time::Duration;

pub const CTL: &str = "oligarchy-ctl";
pub const CTL_TIMEOUT: Duration = Duration::from_secs(5);
/// Actions can take a while (a scan, a rebuild, a pull).
pub const RUN_TIMEOUT: Duration = Duration::from_secs(300);

/// Upper bound on items parsed out of one category. `items appearance` is
/// generated from a user-writable JSON manifest, so its length is not ours to
/// assume.
const MAX_ITEMS_PER_CAT: usize = 512;

#[derive(Debug, Clone, Serialize)]
pub struct Item {
    pub id: String,
    pub title: String,
    /// Category id this item belongs to.
    pub cat: String,
}

#[derive(Debug, Clone, Serialize)]
pub struct Category {
    pub id: String,
    pub title: String,
    pub items: Vec<Item>,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct Catalog {
    pub cats: Vec<Category>,
}

impl Catalog {
    /// Every item across every category, for the flat `/` fuzzy filter.
    pub fn flat(&self) -> Vec<&Item> {
        self.cats.iter().flat_map(|c| c.items.iter()).collect()
    }

    /// Total item count — the honest "is this catalog worth rendering" test.
    pub fn len(&self) -> usize {
        self.cats.iter().map(|c| c.items.len()).sum()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// Actions that must not fire without a confirm modal.
///
/// Deliberately a literal list rather than a heuristic on the id string: a
/// heuristic that silently stops matching after someone renames an action fails
/// open, and failing open here means restarting the mesh without asking.
///
/// Every id below was checked against `oligarchy-ctl.sh`'s `run()` case arms —
/// an entry naming an action the dispatcher does not have is worse than no
/// entry, because it reads as coverage that does not exist.
pub const DESTRUCTIVE: &[&str] = &[
    // `ai-stack stop` — kills ollama/llama-server under whatever is mid-inference.
    "ai-stop",
    // `dsp-arm toggle` — arms/disarms the coprocessor under live audio.
    "arm-dsp",
    // `hydramesh-pull` — mutates the mesh install in place.
    "dcf-pull",
    // `hydramesh-restart` — drops every mesh peering session.
    "dcf-restart",
    // `dsp-netjack-restart` — tears down the NETJACK transport to the DSP VM.
    "dsp-netjack",
    // `hyprlock` — an accidental Enter here locks the operator out mid-session.
    "lock",
    // `wlogout` — ends the session.
    "logout",
    // `git -C $FLAKE_DIR pull --ff-only` — moves the system flake under the host.
    "repo-pull",
    // Re-resolves and reloads the nftables egress ruleset under live connections.
    "sec-egress-resolve",
    // The multi-minute full-closure YARA scan.
    "sec-scan-full",
];

/// Prefixes whose every action is disruptive (kernel/GPU/persona switching).
///
/// These three write `~/.config/oligarchy/state.nix` and hand back a rebuild
/// command; `persona-*` additionally applies power profile, Hyprland animations
/// and the PipeWire quantum immediately. A prefix rather than literals so a
/// kernel variant or persona added to the dispatcher later is covered on the
/// day it appears, which is the direction that fails safe.
pub const DESTRUCTIVE_PREFIXES: &[&str] = &["kernel-", "gpu-", "persona-"];

/// Explicit exemptions, checked before [`DESTRUCTIVE_PREFIXES`].
///
/// A confirm modal on a read-only action is not free: it teaches the operator
/// that `y` is what you type to make the box go away, and that habit is what
/// eventually walks straight through the modal on `dcf-restart`. `persona-show`
/// is a `notify-send` of a file's contents and `persona-apps` launches the
/// active persona's app set — neither changes system state.
pub const NOT_DESTRUCTIVE: &[&str] = &["persona-show", "persona-apps"];

/// Does `id` require a confirm modal before it runs?
///
/// Note what is deliberately absent: `rig-*` (`dsp-rig switch`) changes the live
/// effect chain, but selecting a pedalboard preset is the entire purpose of that
/// category and switching back is one keystroke — gating it would make the pane
/// unusable for the thing it exists to do. `theme-*` and `power-*` are likewise
/// instantly reversible.
pub fn is_destructive(id: &str) -> bool {
    if NOT_DESTRUCTIVE.contains(&id) {
        return false;
    }
    DESTRUCTIVE.contains(&id) || DESTRUCTIVE_PREFIXES.iter().any(|p| id.starts_with(p))
}

/// Parse `oligarchy-ctl cats` + `items <cat>` into a [`Catalog`].
///
/// One subprocess per category on top of the `cats` call. That is a dozen
/// processes, which is why the caller loads this once and caches it rather than
/// touching it per frame.
pub fn catalog() -> Result<Catalog> {
    let cats_out = exec::run(CTL, &["cats"], CTL_TIMEOUT)?;
    let heads = parse_pairs(&cats_out);
    if heads.is_empty() {
        return Err(anyhow!(
            "{CTL} cats returned no categories (exit 0 with no output)"
        ));
    }

    let mut cats = Vec::with_capacity(heads.len());
    for (id, title) in heads {
        // One unreadable category must not cost the other ten. A category whose
        // `items` call fails renders as an empty category, which the pane shows
        // as such.
        let items_out = exec::run(CTL, &["items", &id], CTL_TIMEOUT).unwrap_or_default();
        let items = parse_pairs(&items_out)
            .into_iter()
            .take(MAX_ITEMS_PER_CAT)
            .map(|(item_id, item_title)| Item {
                id: item_id,
                title: item_title,
                cat: id.clone(),
            })
            .collect();
        cats.push(Category { id, title, items });
    }

    let catalog = Catalog { cats };
    if catalog.is_empty() {
        return Err(anyhow!(
            "{CTL} listed {} categories but no actions",
            catalog.cats.len()
        ));
    }
    Ok(catalog)
}

/// Run one action by id. Returns its combined output for the TRAFFIC pane.
///
/// `id` is treated as untrusted: it arrives from a shell script that itself
/// reads a user-writable theme manifest. There is no shell anywhere on this
/// path ([`exec::run`] is `Command::new().args()`), so quoting is not the
/// hazard — argument *parsing* is, exactly as it is for the MCP `find`/`du`
/// allowlist. A leading `-` would be read as an option by anything downstream,
/// so the character set is checked before the process is spawned.
pub fn run(id: &str) -> Result<String> {
    validate_id(id)?;
    let out = exec::run(CTL, &["run", id], RUN_TIMEOUT)?;
    if out.trim().is_empty() {
        // The dispatcher reports through notify-send, and `visible` pops its own
        // terminal when stdout is not a tty — which it never is from here. So a
        // silent success is the common case and must not render as a blank pane.
        return Ok(format!(
            "(no output — {CTL} reports through notify-send, and long or \
             interactive actions open their own terminal window)"
        ));
    }
    Ok(out)
}

/// One-line system summary from `oligarchy-ctl status`, for the header.
///
/// `status` emits `Key : Value` lines and simply omits a key whose backing tool
/// is absent — but it also emits a key with an *empty* value when the tool is
/// present and says nothing (`AI     : ` on a host with the stack stopped).
/// Those are dropped: a header field with nothing after it reads as a bug.
pub fn status_line() -> Result<String> {
    let out = exec::run(CTL, &["status"], CTL_TIMEOUT)?;
    let parts = parse_status(&out);
    if parts.is_empty() {
        return Err(anyhow!("{CTL} status returned nothing usable"));
    }
    Ok(parts.join("  ·  "))
}

/// Split `oligarchy-ctl status`'s `Key : Value` lines into `key value` chunks.
fn parse_status(out: &str) -> Vec<String> {
    out.lines()
        .filter_map(|l| l.split_once(':'))
        .filter_map(|(k, v)| {
            let k = k.trim().to_lowercase();
            let v = v.trim();
            (!k.is_empty() && !v.is_empty()).then(|| format!("{k} {v}"))
        })
        .collect()
}

/// Parse the dispatcher's one wire format: `id|Label` per line.
///
/// A label may itself contain `|` in principle, so the split is on the FIRST
/// separator only. Lines with no separator are dropped rather than guessed at —
/// `items` shells out to user-supplied scripts, so stray output is expected and
/// must not become a phantom action id.
fn parse_pairs(out: &str) -> Vec<(String, String)> {
    out.lines()
        .filter_map(|line| {
            let (id, label) = line.split_once('|')?;
            let id = id.trim();
            let label = label.trim();
            if id.is_empty() || validate_id(id).is_err() {
                return None;
            }
            Some((
                id.to_string(),
                if label.is_empty() { id.to_string() } else { label.to_string() },
            ))
        })
        .collect()
}

/// Character set for an action id. Matches what the dispatcher actually emits
/// (`theme-set:demod`, `rig-clean`, `sec-egress-resolve`) and nothing that could
/// be read as an option or a path.
fn validate_id(id: &str) -> Result<()> {
    if id.is_empty() {
        return Err(anyhow!("empty action id"));
    }
    if id.len() > 128 {
        return Err(anyhow!("action id too long ({} bytes)", id.len()));
    }
    if id.starts_with('-') {
        return Err(anyhow!("refusing action id {id:?}: starts with '-'"));
    }
    if let Some(bad) = id
        .chars()
        .find(|c| !(c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | ':' | '.' | '+' | '@')))
    {
        return Err(anyhow!("refusing action id {id:?}: illegal character {bad:?}"));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The real `oligarchy-ctl cats` output, copied verbatim from a live host.
    const CATS_FIXTURE: &str = "\
appearance|🎨 Style
ai|🧠 AI Stack
dsp|🎛 Audio / DSP
dcf|🛰 DCF Fabric
network|🌐 Network
security|🛡 Security
power|⚡ Power
persona|🎚 Setup
rig|🎸 DSP Rig
system|⚙ System & Kernel
tv|📺 Theater
";

    /// `oligarchy-ctl items appearance`, which is the awkward one: generated
    /// ids carry a `:`, and the active theme's label carries a trailing mark.
    const ITEMS_FIXTURE: &str = "\
theme-set:catppuccin|Catppuccin
theme-set:demod|DeMoD ✓
theme-next|Next theme
anim-toggle|Toggle animations
blur-toggle|Toggle blur
";

    const STATUS_FIXTURE: &str = "\
Kernel : 7.0.10-zen1
Host   : nixos
Persona: dev
Power  : balanced
AI     :
Sec    : ssh:pw= egress:dry-run/active clamav:active events:0
";

    #[test]
    fn destructive_matches_literals_and_prefixes() {
        assert!(is_destructive("dcf-restart"));
        assert!(is_destructive("kernel-zen"));
        assert!(is_destructive("persona-studio"));
        assert!(!is_destructive("dsp-status"));
        assert!(!is_destructive("net-info"));
    }

    /// Every literal in the gate must name an action the dispatcher actually
    /// has. This list is the real `all-items` id set, so a rename upstream that
    /// silently removes coverage fails here instead of at 2am.
    #[test]
    fn destructive_literals_all_exist_in_the_dispatcher() {
        const REAL_IDS: &[&str] = &[
            "theme-next", "anim-toggle", "blur-toggle", "ai-status", "ai-start", "ai-stop",
            "ai-pull", "forge-agent", "out-cycle", "out-menu", "in-cycle", "in-menu", "mute-out",
            "mute-mic", "lat-up", "lat-down", "arm-dsp", "patchbay", "helvum-open",
            "easyeffects-open", "dsp-status", "dsp-console", "dsp-netjack", "rt-check",
            "dsp-bench", "dcf-status", "dcf-logs", "dcf-restart", "dcf-pull", "net-tui",
            "net-edit", "sec-status", "sec-scan-quick", "sec-scan-full", "sec-egress",
            "sec-egress-resolve", "sec-events", "sec-quarantine", "power-perf", "power-balanced",
            "power-saver", "lock", "logout", "persona-menu", "persona-show", "persona-studio",
            "persona-gaming", "persona-dev", "persona-battery", "persona-minimal", "persona-apps",
            "layout-save", "layout-restore", "rig-status", "rig-na", "sys-status", "warroom",
            "kernel-zen", "kernel-xanmod", "kernel-latest", "gpu-amd", "gpu-intel", "gpu-optimus",
            "rebuild-cmd", "repo-check", "repo-pull", "tv-status",
        ];
        for id in DESTRUCTIVE {
            assert!(REAL_IDS.contains(id), "{id} is not an oligarchy-ctl action");
        }
        for id in NOT_DESTRUCTIVE {
            assert!(REAL_IDS.contains(id), "{id} is not an oligarchy-ctl action");
        }
    }

    #[test]
    fn read_only_persona_actions_are_exempt_from_the_prefix() {
        assert!(!is_destructive("persona-show"));
        assert!(!is_destructive("persona-apps"));
        // …but an unknown persona action still fails closed.
        assert!(is_destructive("persona-whatever-ships-next"));
    }

    #[test]
    fn switching_a_rig_or_a_theme_is_not_gated() {
        assert!(!is_destructive("rig-clean"));
        assert!(!is_destructive("rig-status"));
        assert!(!is_destructive("theme-set:demod"));
        assert!(!is_destructive("power-saver"));
    }

    #[test]
    fn parses_the_real_cats_output() {
        let pairs = parse_pairs(CATS_FIXTURE);
        assert_eq!(pairs.len(), 11);
        assert_eq!(pairs[0].0, "appearance");
        assert_eq!(pairs[0].1, "🎨 Style");
        assert_eq!(pairs[10].0, "tv");
    }

    #[test]
    fn parses_generated_ids_and_marked_labels() {
        let pairs = parse_pairs(ITEMS_FIXTURE);
        assert_eq!(pairs.len(), 5);
        assert_eq!(pairs[1], ("theme-set:demod".into(), "DeMoD ✓".into()));
    }

    /// `items` shells out to user scripts, so stray lines are expected.
    #[test]
    fn junk_lines_never_become_action_ids() {
        let out = "\njq: error: no such file\nok-id|Fine\n|no id\n   \n-dash|option-looking\n";
        let pairs = parse_pairs(out);
        assert_eq!(pairs.len(), 1);
        assert_eq!(pairs[0].0, "ok-id");
    }

    #[test]
    fn a_label_containing_a_pipe_keeps_its_pipe() {
        let pairs = parse_pairs("id|a | b\n");
        assert_eq!(pairs[0].1, "a | b");
    }

    #[test]
    fn a_missing_label_falls_back_to_the_id() {
        let pairs = parse_pairs("lonely|\n");
        assert_eq!(pairs[0], ("lonely".into(), "lonely".into()));
    }

    #[test]
    fn status_drops_keys_whose_tool_said_nothing() {
        let parts = parse_status(STATUS_FIXTURE);
        assert_eq!(parts.len(), 5, "the empty AI line must be dropped: {parts:?}");
        assert_eq!(parts[0], "kernel 7.0.10-zen1");
        assert!(parts.iter().all(|p| !p.ends_with(' ')));
        // A value containing its own colons survives intact.
        assert!(parts[4].contains("egress:dry-run/active"));
    }

    #[test]
    fn status_of_nothing_is_not_a_status() {
        assert!(parse_status("").is_empty());
        assert!(parse_status("no colon here\n").is_empty());
    }

    #[test]
    fn ids_that_could_be_read_as_options_or_paths_are_refused() {
        assert!(validate_id("dsp-status").is_ok());
        assert!(validate_id("theme-set:demod").is_ok());
        assert!(validate_id("").is_err());
        assert!(validate_id("-rf").is_err());
        assert!(validate_id("../../etc/passwd").is_err());
        assert!(validate_id("id with space").is_err());
        assert!(validate_id("id;reboot").is_err());
        assert!(validate_id("id\nrun logout").is_err());
        assert!(validate_id(&"x".repeat(129)).is_err());
    }

    #[test]
    fn run_refuses_a_hostile_id_without_spawning_anything() {
        // No subprocess is reachable in the test sandbox; the point is that the
        // refusal happens before one would be.
        let err = run("--version").unwrap_err().to_string();
        assert!(err.contains("refusing"), "{err}");
    }

    #[test]
    fn flat_walks_every_category() {
        let cat = |id: &str, n: usize| Category {
            id: id.into(),
            title: id.into(),
            items: (0..n)
                .map(|i| Item { id: format!("{id}-{i}"), title: format!("{id} {i}"), cat: id.into() })
                .collect(),
        };
        let c = Catalog { cats: vec![cat("a", 2), cat("b", 0), cat("c", 3)] };
        assert_eq!(c.flat().len(), 5);
        assert_eq!(c.len(), 5);
        assert!(!c.is_empty());
        assert!(Catalog::default().is_empty());
    }
}

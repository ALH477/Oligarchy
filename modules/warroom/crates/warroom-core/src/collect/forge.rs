//! FORGE collector — oligarchy-forge session state (rollup only in v1)
//!
//! OWNER: work stream S1.
//!
//! This collector **forks nothing**. `oligarchy-forge` has no `status` or
//! `list` verb (`build`/`run`/`shell`/`tui`/`edit`/`render` only), and the way
//! `forge-tui` answers "is this session built?" is
//! `forge_core::process::image_exists`, which shells out to `podman image
//! exists` — one fork per project, per tick. That is the wrong trade for a
//! 15-second rollup pane whose whole job is a count; the real forge UI is
//! `oligarchy-forge tui` and it can afford it.
//!
//! So state is read straight off disk, exactly where `forge_core::process`
//! writes it: `$XDG_STATE_HOME/oligarchy-forge/<project>/`, holding a generated
//! `flake.nix` and (since `persist_config`) an `oligarchy-forge.toml` snapshot.
//!
//! Note the limitation this makes honest: **nothing on disk records a build
//! result.** `build_and_load_streaming` streams its outcome to a channel and
//! persists no marker. The most recent mtime under a session dir is therefore
//! reported as "last activity", not "last build" — naming it the latter would
//! be a claim the data does not support.

use crate::model::{Availability, Health, Panel};
use std::path::PathBuf;
use std::time::{Duration, SystemTime};

pub struct ForgeCollector {
    _priv: (),
}

impl ForgeCollector {
    pub fn new() -> Self {
        ForgeCollector { _priv: () }
    }
}

impl Default for ForgeCollector {
    fn default() -> Self {
        Self::new()
    }
}

/// Mirrors `forge_core::process::state_root()`. Duplicated rather than
/// depended on: `warroom-core` does not take `forge-core` as a dependency, and
/// one path constant is a cheaper coupling than a whole crate.
fn state_root() -> Option<PathBuf> {
    std::env::var_os("XDG_STATE_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".local/state")))
        .map(|base| base.join("oligarchy-forge"))
}

struct Session {
    name: String,
    /// `persist_config` wrote a snapshot — the session has been through a
    /// `build` at least once with the current code.
    has_config: bool,
    has_flake: bool,
    modified: Option<SystemTime>,
}

fn newest_mtime(dir: &std::path::Path) -> Option<SystemTime> {
    let entries = std::fs::read_dir(dir).ok()?;
    entries
        .filter_map(Result::ok)
        .filter_map(|e| e.metadata().ok())
        .filter_map(|m| m.modified().ok())
        .max()
}

/// Scan the state root. A directory we cannot read is skipped, never fatal —
/// one broken session must not blank the pane (the same rule `forge-tui`'s
/// `discover()` follows).
fn scan(root: &std::path::Path) -> Vec<Session> {
    let Ok(entries) = std::fs::read_dir(root) else {
        return Vec::new();
    };
    let mut out: Vec<Session> = entries
        .filter_map(Result::ok)
        .filter(|e| e.file_type().map(|t| t.is_dir()).unwrap_or(false))
        .map(|e| {
            let path = e.path();
            Session {
                name: e.file_name().to_string_lossy().into_owned(),
                has_config: path.join("oligarchy-forge.toml").is_file(),
                has_flake: path.join("flake.nix").is_file(),
                modified: newest_mtime(&path),
            }
        })
        .collect();
    out.sort_by(|a, b| a.name.cmp(&b.name));
    out
}

fn fmt_ago(d: Duration) -> String {
    let s = d.as_secs();
    if s < 90 {
        format!("{s}s ago")
    } else if s < 5_400 {
        format!("{}m ago", s / 60)
    } else if s < 172_800 {
        format!("{}h ago", s / 3600)
    } else {
        format!("{}d ago", s / 86_400)
    }
}

fn ago(t: Option<SystemTime>) -> String {
    match t.and_then(|t| SystemTime::now().duration_since(t).ok()) {
        Some(d) => fmt_ago(d),
        None => "--".to_string(),
    }
}

impl super::Collector for ForgeCollector {
    fn id(&self) -> &'static str {
        "forge"
    }

    fn title(&self) -> &'static str {
        "FORGE"
    }

    fn interval(&self) -> Duration {
        Duration::from_secs(15)
    }

    fn probe(&self) -> Availability {
        match crate::exec::which("oligarchy-forge") {
            Some(_) => Availability::Present,
            None => {
                Availability::Missing("oligarchy-forge not installed — enable custom.oligarchyForge")
            }
        }
    }

    fn collect(&mut self) -> anyhow::Result<Panel> {
        let root = state_root()
            .ok_or_else(|| anyhow::anyhow!("neither XDG_STATE_HOME nor HOME is set"))?;

        // A state root that has never existed is the correct answer for a user
        // who has never run a build — not an error, and not a health claim.
        if !root.exists() {
            return Ok(Panel::new(Health::Unknown, "no forge sessions")
                .plain("sessions", "0")
                .plain("state root", root.display().to_string()));
        }

        let sessions = scan(&root);
        if sessions.is_empty() {
            return Ok(Panel::new(Health::Unknown, "no forge sessions")
                .plain("sessions", "0")
                .plain("state root", root.display().to_string()));
        }

        let configured = sessions.iter().filter(|s| s.has_config).count();
        let latest = sessions.iter().filter_map(|s| s.modified).max();

        // Good means "the forge's on-disk state is coherent": at least one
        // session carries the config snapshot that makes it reloadable. A dir
        // with only a generated flake is leftover state from before
        // `persist_config` (or a half-finished `edit`), which is worth showing
        // but is not a fault.
        let health = if configured > 0 { Health::Good } else { Health::Unknown };

        let rows: Vec<Vec<String>> = sessions
            .iter()
            .map(|s| {
                vec![
                    s.name.clone(),
                    if s.has_config { "yes" } else { "no" }.to_string(),
                    if s.has_flake { "yes" } else { "no" }.to_string(),
                    ago(s.modified),
                ]
            })
            .collect();

        let panel = Panel::new(health, String::new())
            .row("sessions", format!("{}", sessions.len()), health)
            .plain("with config", format!("{configured}"))
            .plain("last activity", ago(latest))
            .table(
                vec![
                    "session".into(),
                    "config".into(),
                    "flake".into(),
                    "last activity".into(),
                ],
                rows,
            );

        let mut panel = panel;
        panel.summary = format!(
            "{} sessions · {configured} with config · last {}",
            sessions.len(),
            ago(latest)
        );
        Ok(panel)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    /// Build a throwaway state root under the process's temp dir. Uses the
    /// pid + a counter so parallel test threads never collide.
    fn tmp_root(tag: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!("warroom-forge-test-{}-{tag}", std::process::id()));
        let _ = fs::remove_dir_all(&p);
        fs::create_dir_all(&p).expect("create test root");
        p
    }

    #[test]
    fn an_absent_root_scans_to_nothing_rather_than_panicking() {
        let missing = std::env::temp_dir().join("warroom-forge-definitely-not-here");
        assert!(scan(&missing).is_empty());
    }

    #[test]
    fn sessions_are_classified_by_what_is_on_disk() {
        let root = tmp_root("classify");
        // Mirrors this host: one dir with a flake but no config snapshot
        // (pre-`persist_config` leftovers) and one complete session.
        fs::create_dir_all(root.join("edit-test")).unwrap();
        fs::write(root.join("edit-test/flake.nix"), "{}").unwrap();
        fs::create_dir_all(root.join("test-ohmypi")).unwrap();
        fs::write(root.join("test-ohmypi/flake.nix"), "{}").unwrap();
        fs::write(root.join("test-ohmypi/oligarchy-forge.toml"), "[project]").unwrap();
        // A stray file at the root is not a session.
        fs::write(root.join("not-a-session"), "x").unwrap();

        let s = scan(&root);
        assert_eq!(s.len(), 2, "only directories are sessions");
        assert_eq!(s[0].name, "edit-test");
        assert!(!s[0].has_config);
        assert!(s[0].has_flake);
        assert_eq!(s[1].name, "test-ohmypi");
        assert!(s[1].has_config);
        assert!(s[1].modified.is_some());

        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn an_empty_root_has_no_sessions() {
        let root = tmp_root("empty");
        assert!(scan(&root).is_empty());
        let _ = fs::remove_dir_all(&root);
    }

    #[test]
    fn ages_format_compactly() {
        assert_eq!(fmt_ago(Duration::from_secs(5)), "5s ago");
        assert_eq!(fmt_ago(Duration::from_secs(600)), "10m ago");
        assert_eq!(fmt_ago(Duration::from_secs(7200)), "2h ago");
        assert_eq!(fmt_ago(Duration::from_secs(604_800)), "7d ago");
    }

    #[test]
    fn an_unreadable_timestamp_is_a_placeholder_not_a_zero() {
        assert_eq!(ago(None), "--");
    }
}

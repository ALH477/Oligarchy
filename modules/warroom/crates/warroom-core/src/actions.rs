//! The action catalog, sourced from `oligarchy-ctl`.
//!
//! OWNER: work stream S4. The types here are the contract S0 froze; the bodies
//! are stubs.
//!
//! The War Room drives `oligarchy-ctl` rather than reimplementing it. That
//! dispatcher (`home/apps/control-center/oligarchy-ctl.sh`, 417 lines) is the
//! shared action registry, and it already has a non-terminal consumer in
//! `modules/hypr-controller/hypr_bridge.py`, which forwards to it over UDP for
//! the Android companion app. Reimplementing its PATH-probing logic in Rust
//! would fork that single source of truth immediately.

use anyhow::Result;
use serde::Serialize;
use std::time::Duration;

pub const CTL: &str = "oligarchy-ctl";
pub const CTL_TIMEOUT: Duration = Duration::from_secs(5);
/// Actions can take a while (a scan, a rebuild, a pull).
pub const RUN_TIMEOUT: Duration = Duration::from_secs(300);

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
}

/// Actions that must not fire without a confirm modal.
///
/// Deliberately a literal list rather than a heuristic on the id string: a
/// heuristic that silently stops matching after someone renames an action fails
/// open, and failing open here means restarting the mesh without asking.
pub const DESTRUCTIVE: &[&str] = &[
    "dcf-restart",
    "sec-scan-full",
    "repo-pull",
    "logout",
    "reboot",
    "poweroff",
];

/// Prefixes whose every action is disruptive (kernel/GPU/persona switching).
pub const DESTRUCTIVE_PREFIXES: &[&str] = &["kernel-", "gpu-", "persona-"];

pub fn is_destructive(id: &str) -> bool {
    DESTRUCTIVE.contains(&id) || DESTRUCTIVE_PREFIXES.iter().any(|p| id.starts_with(p))
}

/// Parse `oligarchy-ctl cats` + `items <cat>` into a [`Catalog`].
pub fn catalog() -> Result<Catalog> {
    anyhow::bail!("actions::catalog not implemented")
}

/// Run one action by id. Returns its combined output for the TRAFFIC pane.
pub fn run(_id: &str) -> Result<String> {
    anyhow::bail!("actions::run not implemented")
}

/// One-line system summary from `oligarchy-ctl status`, for the header.
pub fn status_line() -> Result<String> {
    anyhow::bail!("actions::status_line not implemented")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn destructive_matches_literals_and_prefixes() {
        assert!(is_destructive("dcf-restart"));
        assert!(is_destructive("kernel-zen"));
        assert!(is_destructive("persona-studio"));
        assert!(!is_destructive("dsp-status"));
        assert!(!is_destructive("net-info"));
    }
}

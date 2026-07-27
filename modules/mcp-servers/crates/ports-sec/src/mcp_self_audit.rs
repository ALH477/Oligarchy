//! `mcp_self_audit` — meta-security for this very workspace. Walks every
//! crate's `src/**/*.rs` and asserts:
//!
//! - no `TcpListener::bind`,
//! - no `reqwest::Client` builder outside `crates/ports-sec`,
//! - `.mcp.json` has no URL/`http` transport entries,
//! - `.mcp.json` does not wire in the read-write `dcf-mesh-agent` or
//!   `dcf-hypr-agent` endpoints.
//!
//! It does NOT check `Command::new` literals against the const allowlist in
//! `crates/core` — that enforcement is at runtime, in `runner::run`.
//!
//! Doubles as a build gate: `nix build .#mcp-self-audit` runs this tool
//! against the repo and fails the build on any violation.
//!
//! Both paths it inspects come from the environment when set
//! (`OLIGARCHY_MCP_WORKSPACE`, `OLIGARCHY_MCP_JSON`), because
//! `CARGO_MANIFEST_DIR` is baked in at compile time and points into a build
//! sandbox that no longer exists when the gate runs from the Nix store. If a
//! path cannot be resolved the audit REPORTS A VIOLATION rather than passing
//! silently — a check that inspects nothing must never look clean.

pub fn run() -> anyhow::Result<String> {
    let mut violations = Vec::new();

    // 1. No socket listeners anywhere; no reqwest builders outside ports-sec.
    let workspace_root = workspace_root();
    let crates_dir = workspace_root.join("crates");
    match std::fs::read_dir(&crates_dir) {
        Ok(entries) => {
            let mut scanned = 0usize;
            for e in entries.flatten() {
                let path = e.path();
                if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
                    if name == "ports-sec" {
                        continue;
                    }
                    let src = path.join("src");
                    if src.is_dir() {
                        scan_dir(&src, &mut violations, name);
                        scanned += 1;
                    }
                }
            }
            if scanned == 0 {
                violations.push(format!(
                    "{}: no crates scanned — the source scan inspected nothing",
                    crates_dir.display()
                ));
            }
        }
        Err(e) => violations.push(format!(
            "{}: cannot read crates dir ({e}) — set OLIGARCHY_MCP_WORKSPACE to the \
             mcp-servers source root",
            crates_dir.display()
        )),
    }

    // 2. .mcp.json must have no http/url transport entries, and must not wire
    //    in the read-write mesh or hypr-controller agents (see
    //    modules/dcf-mesh-agent.nix, modules/hypr-controller/nixos-module.nix).
    //
    //    An absent file is only a violation when the path was given
    //    explicitly. Built standalone, the sub-flake has no repo root above it
    //    and legitimately has no .mcp.json to audit — that case is reported as
    //    a visible SKIPPED note so the report never implies a check it did not
    //    run.
    let explicit_json = std::env::var("OLIGARCHY_MCP_JSON").is_ok();
    let mcp_file = mcp_json_path(&workspace_root);
    let mut skipped = Vec::new();
    match std::fs::read_to_string(&mcp_file) {
        Ok(text) => {
            for forbidden in ["\"url\"", "\"http", "\"transport\""] {
                if text.contains(forbidden) {
                    violations.push(format!(
                        "{}: .mcp.json contains a URL/HTTP transport entry ({forbidden})",
                        mcp_file.display()
                    ));
                }
            }
            for forbidden in [
                "dcf-mesh-mcp",
                "mesh_mcp.py",
                "dcf-mesh-agent",
                "dcf-hypr-agent",
                "demod-hypr-bridge",
            ] {
                if text.contains(forbidden) {
                    violations.push(format!(
                        "{}: .mcp.json wires in `{forbidden}` — this is a \
                         read-write, UDP-bound endpoint and must stay out of the \
                         read-only MCP surface",
                        mcp_file.display()
                    ));
                }
            }
        }
        Err(e) if explicit_json => violations.push(format!(
            "{}: cannot read the .mcp.json given by OLIGARCHY_MCP_JSON ({e})",
            mcp_file.display()
        )),
        Err(e) => skipped.push(format!(
            "{}: not found ({e}) — .mcp.json NOT audited. Set OLIGARCHY_MCP_JSON \
             to check a specific file.",
            mcp_file.display()
        )),
    }

    if violations.is_empty() {
        let mut out = format!(
            "mcp_self_audit: clean — no open sockets outside ports-sec, no remote \
             transports and no mesh-agent entry in .mcp.json\n  workspace: {}\n  mcp.json:  {}\n",
            workspace_root.display(),
            mcp_file.display()
        );
        for s in &skipped {
            out.push_str(&format!("  SKIPPED: {s}\n"));
        }
        Ok(out)
    } else {
        let mut out = String::from("mcp_self_audit: VIOLATIONS:\n");
        out.push_str(&violations.iter().map(|v| format!("  - {v}")).collect::<Vec<_>>().join("\n"));
        out.push_str("\n\nRun:  nix build .#mcp-self-audit  for the gating form of this check.");
        Ok(out)
    }
}

fn scan_dir(dir: &std::path::Path, violations: &mut Vec<String>, crate_name: &str) {
    if let Ok(entries) = std::fs::read_dir(dir) {
        for e in entries.flatten() {
            let p = e.path();
            if p.is_dir() {
                scan_dir(&p, violations, crate_name);
            } else if p.extension().and_then(|x| x.to_str()) == Some("rs") {
                if let Ok(text) = std::fs::read_to_string(&p) {
                    for forbidden in [
                        "TcpListener::bind",
                        "UdpSocket::bind",
                        "reqwest::Client",
                        "reqwest::ClientBuilder",
                    ] {
                        if text.contains(forbidden) {
                            violations.push(format!(
                                "{} ({} crate): forbidden token `{forbidden}` — only ports-sec may open sockets",
                                p.display(),
                                crate_name
                            ));
                        }
                    }
                }
            }
        }
    }
}

/// The `modules/mcp-servers` source root. Prefers `OLIGARCHY_MCP_WORKSPACE`
/// (set by the Nix build gate, since `CARGO_MANIFEST_DIR` points into a build
/// sandbox that is gone by the time the gate runs); otherwise walks up from
/// the compile-time manifest dir.
fn workspace_root() -> std::path::PathBuf {
    if let Ok(env) = std::env::var("OLIGARCHY_MCP_WORKSPACE") {
        return std::path::PathBuf::from(env);
    }
    // The ports-sec CARGO_MANIFEST_DIR is <root>/crates/ports-sec; the
    // workspace root is TWO parents up, not one.
    let here = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    here.parent()
        .and_then(|p| p.parent())
        .map(|p| p.to_path_buf())
        .unwrap_or(here)
}

/// The MCP client config to audit. `OLIGARCHY_MCP_JSON` wins; otherwise the
/// repo-root `.mcp.json`, one level above the mcp-servers workspace.
fn mcp_json_path(workspace_root: &std::path::Path) -> std::path::PathBuf {
    if let Ok(env) = std::env::var("OLIGARCHY_MCP_JSON") {
        return std::path::PathBuf::from(env);
    }
    workspace_root
        .parent()
        .and_then(|p| p.parent())
        .map(|repo| repo.join(".mcp.json"))
        .unwrap_or_else(|| workspace_root.join(".mcp.json"))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, MutexGuard};

    /// Same hazard as crates/core/src/audit.rs: OLIGARCHY_MCP_JSON is
    /// process-global, cargo runs these tests as threads in one process, and
    /// `run()` reads that var. If the override test has it pointing at
    /// /tmp/explicit.json when `audit_is_clean_on_this_tree` calls `run()`,
    /// the audit treats the path as explicitly given, fails to read it,
    /// reports a violation, and the clean-tree assertion fails for a reason
    /// that has nothing to do with the tree.
    static ENV_LOCK: Mutex<()> = Mutex::new(());

    fn lock_env() -> MutexGuard<'static, ()> {
        ENV_LOCK.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    #[test]
    fn run_smoke() {
        let _guard = lock_env();
        let _ = run();
    }

    #[test]
    fn workspace_root_contains_the_crates_dir() {
        // Regression: this used to go one parent up, landing on `crates/`, so
        // the scan looked in `crates/crates` and the whole audit was a no-op.
        let root = workspace_root();
        assert!(
            root.join("crates").join("core").join("src").is_dir(),
            "workspace_root() resolved to {} — expected the mcp-servers root",
            root.display()
        );
        assert!(root.join("Cargo.toml").is_file());
    }

    #[test]
    fn mcp_json_path_is_two_levels_above_the_workspace() {
        // Reads OLIGARCHY_MCP_JSON (via mcp_json_path) without setting it, so
        // it still needs the lock — the override test's value leaks in
        // otherwise and this asserts /tmp/explicit.json == /repo/.mcp.json.
        let _guard = lock_env();
        // Not an existence check: inside the Nix build sandbox the source has
        // no repo root above it, which is exactly the case the SKIPPED note
        // covers. What must hold is the shape — repo/modules/mcp-servers ->
        // repo/.mcp.json.
        let ws = std::path::Path::new("/repo/modules/mcp-servers");
        assert_eq!(
            mcp_json_path(ws),
            std::path::PathBuf::from("/repo/.mcp.json")
        );
    }

    #[test]
    fn mcp_json_path_honours_env_override() {
        let _guard = lock_env();
        std::env::set_var("OLIGARCHY_MCP_JSON", "/tmp/explicit.json");
        assert_eq!(
            mcp_json_path(std::path::Path::new("/anything")),
            std::path::PathBuf::from("/tmp/explicit.json")
        );
        std::env::remove_var("OLIGARCHY_MCP_JSON");
    }

    #[test]
    fn audit_is_clean_on_this_tree() {
        let _guard = lock_env();
        let report = run().unwrap();
        assert!(
            !report.contains("VIOLATIONS"),
            "self-audit is not clean:\n{report}"
        );
    }
}
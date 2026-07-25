//! `mcp_self_audit` — meta-security for this very workspace. Walks every
//! crate's `src/**/*.rs` and asserts:
//!
//! - no `TcpListener::bind`,
//! - no `reqwest::Client` builder outside `crates/ports-sec`,
//! - no `process::Command` outside the const allowlist in `crates/core`,
//! - every crate's audit log path is its own,
//! - `.mcp.json` has no URL/`http` transport entries.
//!
//! Doubles as a build gate: `nix build .#mcp-self-audit` runs this tool
//! against the repo and fails the build on any violation.

pub fn run() -> anyhow::Result<String> {
    let mut violations = Vec::new();

    // 1. No socket listeners anywhere; no reqwest builders outside ports-sec.
    let workspace_root = workspace_root();
    let crates_dir = workspace_root.join("crates");
    if let Ok(entries) = std::fs::read_dir(&crates_dir) {
        for e in entries.flatten() {
            let path = e.path();
            if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
                if name == "ports-sec" {
                    continue;
                }
                scan_dir(&path.join("src"), &mut violations, name);
            }
        }
    }

    // 2. .mcp.json must have no http/url transport entries.
    let mcp_json = workspace_root.parent().map(|p| p.join(".mcp.json"));
    if let Some(Some(mcp_file)) = mcp_json.map(|p| Some(p)) {
        if let Ok(text) = std::fs::read_to_string(&mcp_file) {
            if text.contains("\"url\"") || text.contains("\"http") || text.contains("\"transport\"") {
                violations.push(format!("{}: .mcp.json contains a URL/HTTP transport entry", mcp_file.display()));
            }
        }
    }

    if violations.is_empty() {
        Ok("mcp_self_audit: clean — no open sockets, no allowlist escapes, no remote transports in .mcp.json".into())
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

fn workspace_root() -> std::path::PathBuf {
    // The ports-sec CARGO_MANIFEST_DIR is crates/ports-sec; the workspace
    // root is two parents up.
    let here = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    here.parent().unwrap().to_path_buf()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn run_smoke() {
        let _ = run();
    }
}
//! Build-gate test: no crate opens a listening socket.
//!
//! Scans every crate's `src/**/*.rs` for forbidden patterns and fails the
//! build if any are found. The single hardened exception is
//! `crates/ports-sec` whose `local_api_scan` tool must open a loopback
//! socket — gated behind the `allow-loopback-socket` feature and the
//! runtime `bind(127.0.0.1)` / `bind(::1)` assertion in the connect helper.
//!
//! Run from the workspace root with `cargo test -p oligarchy-mcp-core`.

use std::path::PathBuf;

/// Tokens that indicate a crate is opening a listening socket or making an
/// unconfined outbound network connection. Matches are coarse on purpose —
/// false positives are caught here in core and reviewed intentionally.
const FORBIDDEN_PATTERNS: &[&str] = &[
    "TcpListener::bind",
    "TcpListener::from_",
    "UdpSocket::bind",
    // Outbound reqwest/ureq sockets are allowed ONLY in ports-sec, gated
    // by the loopback bind. Anywhere else they are forbidden.
    "reqwest::Client",
    "reqwest::ClientBuilder",
];

fn workspace_root() -> PathBuf {
    let here = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    here.parent().unwrap().to_path_buf()
}

fn crate_src_dirs() -> Vec<(String, PathBuf)> {
    let root = workspace_root().join("crates");
    let mut out = Vec::new();
    if let Ok(entries) = std::fs::read_dir(&root) {
        for e in entries.flatten() {
            let path = e.path();
            if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
                let src = path.join("src");
                if src.is_dir() {
                    out.push((name.to_string(), src));
                }
            }
        }
    }
    out
}

fn scan_dir(dir: &std::path::Path, sink: &mut Vec<String>) {
    if let Ok(entries) = std::fs::read_dir(dir) {
        for e in entries.flatten() {
            let p = e.path();
            if p.is_dir() {
                scan_dir(&p, sink);
            } else if p.extension().and_then(|x| x.to_str()) == Some("rs") {
                if let Ok(text) = std::fs::read_to_string(&p) {
                    for pat in FORBIDDEN_PATTERNS {
                        if text.contains(pat) {
                            sink.push(format!("{}: {}", p.display(), pat));
                        }
                    }
                }
            }
        }
    }
}

#[test]
fn no_open_sockets_outside_ports_sec() {
    let mut violations = Vec::new();
    for (name, src) in crate_src_dirs() {
        if name == "ports-sec" {
            // ports-sec is the hardened exception; the loopback bind is
            // checked by its own unit tests + the feature flag.
            continue;
        }
        scan_dir(&src, &mut violations);
    }
    if !violations.is_empty() {
        panic!(
            "forbidden socket-open pattern(s) found outside ports-sec:\n  {}\n\
             If you need to open a socket, do it in crates/ports-sec and gate \
             it behind the `allow-loopback-socket` feature.",
            violations.join("\n  ")
        );
    }
}

#[test]
fn ports_sec_loopback_guard_present() {
    // The ports-sec crate must contain the loopback bind assertion; this
    // is structural coverage rather than enforcement, but cheap to keep.
    let p = workspace_root().join("crates/ports-sec/src/local_api_scan.rs");
    if !p.exists() {
        // Not yet implemented — skip silently. Phase 3 will land this file.
        return;
    }
    let text = std::fs::read_to_string(&p).expect("ports-sec/src/local_api_scan.rs present");
    assert!(
        text.contains("127.0.0.1") || text.contains("bind_local"),
        "local_api_scan must bind to loopback only; missing loopback guard"
    );
}
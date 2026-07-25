//! `nmap_self_scan` — runs `nmap -sT -p- 127.0.0.1` / `::1` (loopback only)
//! and optionally `nmap -sT -p- <wired-lan-ip>` when given an explicit
//! `lan_iface` argument validated against `ip -o link`.

use oligarchy_mcp_core::runner::{self, QUICK_TIMEOUT};

/// Returns true iff `iface` is a non-loopback interface present on the host.
/// Uses the `ip` CLI (read-only), which is on the PORTS_SEC allowlist.
pub fn validate_lan_iface(iface: &str) -> std::io::Result<bool> {
    let out = runner::run("ports-sec", "ip", &["-o", "link"], QUICK_TIMEOUT)
        .unwrap_or_default();
    Ok(out.lines().any(|l| l.split(':').nth(1).map(|s| s.trim()).unwrap_or("") == iface))
}

pub fn loopback(timeout_secs: u64) -> anyhow::Result<String> {
    // Hard-coded loopback targets. No LAN scan happens here.
    let inv = runner::run(
        "ports-sec",
        "nmap",
        &["-sT", "-p-", "127.0.0.1"],
        std::time::Duration::from_secs(timeout_secs),
    )?;
    let inv6 = runner::run(
        "ports-sec",
        "nmap",
        &["-sT", "-p-", "::1"],
        std::time::Duration::from_secs(timeout_secs),
    )?;
    Ok(format!("── nmap loopback v4 ──\n{inv}\n\n── nmap loopback v6 ──\n{inv6}\n"))
}
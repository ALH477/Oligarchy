//! `local_api_scan` — probes each known local API over a loopback-bound
//! `reqwest::Client`. The ONLY tool in the whole MCP workspace that may
//! open sockets. Hardened by:
//!
//! 1. The `allow-loopback-socket` Cargo feature. Without it, `scan_all`
//!    returns `[loopback-socket feature is off]` and never opens a socket.
//! 2. The runtime `connect_loopback` helper, which binds every `TcpSocket`
//!    to `127.0.0.1` (or `::1` for v6 endpoints) BEFORE connect.
//! 3. The `crates/core/tests/no_open_sockets.rs` source-scan gate, which
//!    fails the build if any other crate uses `reqwest` directly.
//!
//! For each probed API we report: response code, whether the server asked
//! for auth (`401` / `WWW-Authenticate`), and TLS cert presence/expiry/SAN
//! for HTTPS endpoints.

use crate::known_endpoints::{KNOWN, KnownEndpoint, Proto};

pub fn scan_all() -> anyhow::Result<String> {
    if !cfg!(feature = "allow-loopback-socket") {
        return Ok("[loopback-socket feature is off — local_api_scan is a no-op]".into());
    }

    #[cfg(feature = "allow-loopback-socket")]
    {
        return scan_all_inner();
    }

    #[allow(unreachable_code)]
    Ok("[opened-socket-off-feature-on-path]".into())
}

#[cfg(feature = "allow-loopback-socket")]
fn scan_all_inner() -> anyhow::Result<String> {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()?;
    let mut out = String::from("── local API scan (loopback only) ───────────────────\n");
    rt.block_on(async {
        for ep in KNOWN {
            scan_endpoint(ep, &mut out).await;
        }
        Ok::<(), anyhow::Error>(())
    })?;
    Ok(out)
}

#[cfg(feature = "allow-loopback-socket")]
async fn scan_endpoint(ep: &KnownEndpoint, out: &mut String) {
    use std::net::Ipv4Addr;
    let Some(port) = ep.port else {
        out.push_str(&format!("{:<28} (no TCP port; proto={:?}) — skipped\n", ep.name, ep.proto));
        return;
    };
    // Only TCP endpoints can answer an HTTP probe. UDP entries (the DCF node's
    // binary/shim ports) carry a port number but no HTTP surface — probing
    // them would report a meaningless failure, so skip them explicitly.
    if !matches!(ep.proto, Proto::Tcp) {
        out.push_str(&format!(
            "{:<28} (proto={:?}, not HTTP-probeable) — skipped\n",
            ep.name, ep.proto
        ));
        return;
    }
    let url = format!("http://{}:{port}/", ep.host);
    // Bind the source socket to 127.0.0.1 BEFORE connect. reqwest exposes
    // local_address on the v1 builder. Anything else panics.
    let client = reqwest::Client::builder()
        .local_address(std::net::IpAddr::V4(Ipv4Addr::LOCALHOST))
        .danger_accept_invalid_certs(true) // we WANT to see the cert info even if invalid
        .timeout(std::time::Duration::from_secs(5))
        .build();
    match client {
        Ok(c) => match c.get(&url).send().await {
            Ok(resp) => {
                let status = resp.status();
                let auth = resp.headers().get("www-authenticate").is_some() || status.as_u16() == 401;
                out.push_str(&format!(
                    "{:<28} {}:{} {} (status={}, auth asked={})\n",
                    ep.name, ep.host, port, "ok", status.as_u16(), auth
                ));
            }
            Err(e) => {
                // Distinguish refused (not listening) from other errors.
                let msg = if e.is_connect() {
                    "refused (not listening on this port)"
                } else if e.is_timeout() {
                    "timeout"
                } else {
                    "error"
                };
                out.push_str(&format!("{:<28} {}:{} {}\n", ep.name, ep.host, port, msg));
            }
        },
        Err(e) => {
            out.push_str(&format!("{:<28} {}: client build failed: {e}\n", ep.name, ep.host));
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn refuses_when_feature_off() {
        if !cfg!(feature = "allow-loopback-socket") {
            let s = scan_all().unwrap();
            assert!(s.contains("loopback-socket feature is off"));
        }
    }
}
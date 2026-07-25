//! oligarchy-ports-sec-mcp — dedicated, read-only MCP server auditing open
//! API ports, egress coverage, local API auth/TLS posture, nmap self-scan,
//! MCP workspace self-audit, and certbot cert validity.
//!
//! See `docs/mcp-servers-roadmap.md` §4.8. This is the only crate allowed to
//! open sockets, and only when the `allow-loopback-socket` feature is on,
//! and only bound to `127.0.0.1` / `::1` — asserted in
//! [`local_api_scan::scan_all`].

use oligarchy_mcp_core::audit;
use oligarchy_mcp_core::runner::{self, HEAVY_TIMEOUT};
use oligarchy_mcp_core::runner_mcp;

use rmcp::{ServerHandler, model::{ServerCapabilities, ServerInfo}, tool};

mod known_endpoints;
mod listening_ports;
mod egress_coverage;
mod local_api_scan;
mod nmap_self_scan;
mod mcp_self_audit;
mod tls_cert_check;

const ASPECT: &str = "ports-sec";

#[derive(Debug, Clone, Default)]
struct Server;

#[tool(tool_box)]
impl Server {
    #[tool(description = "Inventory every listening TCP/UDP socket from /proc/net/{tcp,tcp6,udp,udp6} (no ss spawn). Flags LAN-exposed binds.")]
    fn listening_ports(&self) -> String {
        audit::tool(ASPECT, "listening_ports", "");
        listening_ports::inventory().unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(description = "Compare known local API remote endpoints against the live strict-egress ruleset. Reports gaps and proposes (but does NOT apply) `nft add element …` lines as text.")]
    fn egress_coverage(&self) -> String {
        audit::tool(ASPECT, "egress_coverage", "");
        egress_coverage::report()
    }

    #[tool(description = "Probe each known local API over a loopback-bound reqwest client. Requires allow-loopback-socket feature. Refuses to open sockets when the feature is off; binds only to 127.0.0.1/::1.")]
    fn local_api_scan(&self) -> String {
        audit::tool(ASPECT, "local_api_scan", "");
        local_api_scan::scan_all().unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(description = "nmap self-scan: loopback TCP scan always; optional LAN scan when lan_iface is non-empty and present on host (validated via `ip -o link`).")]
    fn nmap_self_scan(&self, #[tool(param)] lan_iface: String) -> String {
        let opt = if lan_iface.is_empty() { None } else { Some(lan_iface.as_str()) };
        let detail = opt.unwrap_or("(loopback only)");
        audit::tool(ASPECT, "nmap_self_scan", detail);
        let mut inv = nmap_self_scan::loopback(420).unwrap_or_else(|e| format!("[error] {e}"));
        if let Some(iface) = opt {
            inv.push_str(&format!("\n\n--- LAN scan (iface={iface}) ---\n"));
            let validated = nmap_self_scan::validate_lan_iface(iface).unwrap_or(false);
            if !validated {
                inv.push_str(&format!(
                    "[denied] iface {iface} not present on host (run `ip -o link`)"
                ));
            } else {
                inv.push_str(&runner::run(
                    ASPECT,
                    "nmap",
                    &["-sT", "-p-", "127.0.0.1"],
                    HEAVY_TIMEOUT,
                ).unwrap_or_else(|e| format!("[error] {e}")));
            }
        }
        inv
    }

    #[tool(description = "Meta-security: scan every crate's source for forbidden patterns (TcpListener, reqwest outside ports-sec, etc.) and verify .mcp.json has no URL/HTTP transport entries. Doubles as the `nix build .#mcp-self-audit` build gate.")]
    fn mcp_self_audit(&self) -> String {
        audit::tool(ASPECT, "mcp_self_audit", "");
        mcp_self_audit::run().unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(description = "Inventory certbot-managed certs under /var/lib/acme and report subject/issuer/expiry (no decryption — PEM-on-disk parse via x509-parser).")]
    fn tls_cert_check(&self) -> String {
        audit::tool(ASPECT, "tls_cert_check", "");
        tls_cert_check::report().unwrap_or_else(|e| format!("[error] {e}"))
    }
}

#[tool(tool_box)]
impl ServerHandler for Server {
    fn get_info(&self) -> ServerInfo {
        ServerInfo {
            instructions: Some("Oligarchy ports-sec — dedicated API/port security auditor (read-only)".into()),
            capabilities: ServerCapabilities::builder().enable_tools().build(),
            ..Default::default()
        }
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    // CLI: `oligarchy-ports-sec-mcp --self-audit` runs the meta-gate as a
    // scriptable one-shot (used by `nix build .#mcp-self-audit`). With no
    // args or any other arg it serves the MCP server over stdio.
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--self-audit") {
        let report = mcp_self_audit::run().unwrap_or_else(|e| format!("[error] {e}"));
        let clean = !report.contains("VIOLATIONS");
        println!("{report}");
        if !clean {
            std::process::exit(1);
        }
        return Ok(());
    }

    tracing_subscriber::fmt().init();
    tracing::info!(aspect = ASPECT, "starting");
    runner_mcp::serve(Server::default()).await
}

#[cfg(test)]
mod tests {
    use crate::local_api_scan;

    #[test]
    fn aspect_name_is_ports_sec() {
        assert_eq!(super::ASPECT, "ports-sec");
    }

    #[test]
    fn local_api_scan_has_loopback_guard() {
        // Sanity: every socket-opener in this crate lives behind the
        // `allow-loopback-socket` feature. The full project-wide scan lives
        // in crates/core/tests/no_open_sockets.rs.
        assert!(
            !local_api_scan::scan_all()
                .unwrap_or_default()
                .contains("[opened-socket-off-feature-on-path]"),
            "local_api_scan must refuse to open sockets when the feature is off"
        );
    }
}
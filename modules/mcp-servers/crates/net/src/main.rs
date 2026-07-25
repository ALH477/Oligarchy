//! oligarchy-net-mcp — read-only MCP server for the network/firewall aspect.
//! See `docs/mcp-servers-roadmap.md` §4.2.

use oligarchy_mcp_core::audit;
use oligarchy_mcp_core::runner::{self, QUICK_TIMEOUT};
use oligarchy_mcp_core::runner_mcp;

use rmcp::{ServerHandler, model::{ServerCapabilities, ServerInfo}, tool};

const ASPECT: &str = "net";

#[derive(Debug, Clone, Default)]
struct Server;

#[tool(tool_box)]
impl Server {
    #[tool(description = "ip -o addr summary (read-only).")]
    fn network_status(&self) -> String {
        audit::tool(ASPECT, "network_status", "");
        runner::run(ASPECT, "ip", &["-o", "addr"], QUICK_TIMEOUT)
            .unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(description = "Strict-egress firewall status (mode, resolved entries, recent blocks).")]
    fn egress_status(&self) -> String {
        audit::tool(ASPECT, "egress_status", "");
        runner::run(ASPECT, "strict-egress-status", &[], QUICK_TIMEOUT)
            .unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(description = "Try connecting to a host through the strict-egress allowlist (read-only probe).")]
    fn egress_test_host(&self, #[tool(param)] host: String) -> String {
        audit::tool(ASPECT, "egress_test_host", &host);
        runner::run(ASPECT, "strict-egress-test", &[&host], QUICK_TIMEOUT)
            .unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(description = "Resolve a DNS name through systemd-resolved (resolvectl query).")]
    fn dns_resolve(&self, #[tool(param)] name: String) -> String {
        audit::tool(ASPECT, "dns_resolve", &name);
        runner::run(ASPECT, "resolvectl", &["query", &name], QUICK_TIMEOUT)
            .unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(description = "List the strict-egress nft table (sets and chain state).")]
    fn nft_list_sets(&self) -> String {
        audit::tool(ASPECT, "nft_list_sets", "");
        runner::run(ASPECT, "nft", &["list", "table", "inet", "strict-egress"], QUICK_TIMEOUT)
            .unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(description = "DeMoD IP blocker service status.")]
    fn ip_blocker_status(&self) -> String {
        audit::tool(ASPECT, "ip_blocker_status", "");
        runner::run(ASPECT, "demod-ip-blocker", &["status"], QUICK_TIMEOUT)
            .unwrap_or_else(|e| format!("[error] {e}"))
    }
}

#[tool(tool_box)]
impl ServerHandler for Server {
    fn get_info(&self) -> ServerInfo {
        ServerInfo {
            instructions: Some("Oligarchy network/firewall aspect — strict-egress, DNS, IP blocker (read-only).".into()),
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
    fn aspect_name_is_net() {
        assert_eq!(ASPECT, "net");
    }
}
//! oligarchy-dcf-mcp — read-only MCP server for the DeMoD Compute Fabric mesh.
//! See `docs/mcp-servers-roadmap.md` §4.3.

use oligarchy_mcp_core::audit;
use oligarchy_mcp_core::runner::{self, QUICK_TIMEOUT};
use oligarchy_mcp_core::runner_mcp;
use oligarchy_mcp_core::sandbox;

use rmcp::{ServerHandler, model::{ServerCapabilities, ServerInfo}, tool};

const ASPECT: &str = "dcf";

#[derive(Debug, Clone, Default)]
struct Server;

#[tool(tool_box)]
impl Server {
    #[tool(description = "DeMoD Compute Fabric (DCF) mesh node status.")]
    fn dcf_status(&self) -> String {
        audit::tool(ASPECT, "dcf_status", "");
        runner::run(ASPECT, "hydramesh-status", &[], QUICK_TIMEOUT)
            .unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(description = "DCF mesh peer list.")]
    fn mesh_peers(&self) -> String {
        audit::tool(ASPECT, "mesh_peers", "");
        runner::run(ASPECT, "hydramesh-peers", &[], QUICK_TIMEOUT)
            .unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(description = "sops identity key PRESENCE only (never decrypt). Shows .sops.yaml path presence.")]
    fn identity_status(&self) -> String {
        audit::tool(ASPECT, "identity_status", "");
        let flake = sandbox::flake_dir();
        let sops_yaml = flake.join(".sops.yaml");
        let present = sops_yaml.is_file();
        format!(
            "sops config: {} ({})",
            sops_yaml.display(),
            if present { "present" } else { "absent" }
        )
    }

    #[tool(description = "DCF tray systemd unit status (read-only).")]
    fn tray_status(&self) -> String {
        audit::tool(ASPECT, "tray_status", "");
        runner::run(
            ASPECT,
            "systemctl",
            &["status", "dcf-tray.service", "--no-pager", "--lines", "0"],
            QUICK_TIMEOUT,
        )
        .unwrap_or_else(|e| format!("[error] {e}"))
    }
}

#[tool(tool_box)]
impl ServerHandler for Server {
    fn get_info(&self) -> ServerInfo {
        ServerInfo {
            instructions: Some("Oligarchy DCF mesh aspect — node status, peers, identity presence (read-only).".into()),
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
    fn aspect_name_is_dcf() {
        assert_eq!(ASPECT, "dcf");
    }
}
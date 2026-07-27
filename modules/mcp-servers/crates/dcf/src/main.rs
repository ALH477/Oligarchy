//! oligarchy-dcf-mcp — read-only MCP server for the Oligarchy DCF services:
//! the community-node container, sops identity presence, and the tray unit.
//! See `docs/mcp-servers-roadmap.md` §4.3.
//!
//! The mesh/protocol stack itself (HydraMesh + DCF SDK CLIs, HydraModem) lives
//! in the `hydramesh` aspect — see §4.9.

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
    #[tool(description = "DeMoD Compute Fabric (DCF) community node service status (read-only).")]
    fn dcf_status(&self) -> String {
        audit::tool(ASPECT, "dcf_status", "");
        runner::run(
            ASPECT,
            "systemctl",
            &["status", "docker-dcf-sdk.service", "--no-pager", "--lines", "0"],
            QUICK_TIMEOUT,
        )
        .or_else(|_| {
            runner::run(
                ASPECT,
                "docker",
                &["inspect", "--format", "{{.State.Status}}", "dcf-sdk"],
                QUICK_TIMEOUT,
            )
        })
        .unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(description = "DCF mesh peer list (via the HydraMesh SDK). See the `hydramesh` aspect for the full mesh surface.")]
    fn mesh_peers(&self) -> String {
        audit::tool(ASPECT, "mesh_peers", "");
        runner::run(ASPECT, "hydramesh", &["list-peers"], QUICK_TIMEOUT)
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
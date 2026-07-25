//! oligarchy-dsp-mcp — read-only MCP server for the DSP/audio coprocessor.
//! See `docs/mcp-servers-roadmap.md` §4.4.

use oligarchy_mcp_core::audit;
use oligarchy_mcp_core::runner::{self, QUICK_TIMEOUT};
use oligarchy_mcp_core::runner_mcp;

use rmcp::{ServerHandler, model::{ServerCapabilities, ServerInfo}, tool};

const ASPECT: &str = "dsp";

#[derive(Debug, Clone, Default)]
struct Server;

#[tool(tool_box)]
impl Server {
    #[tool(description = "Real-time DSP coprocessor / audio status (dsp-status).")]
    fn dsp_status(&self) -> String {
        audit::tool(ASPECT, "dsp_status", "");
        runner::run(ASPECT, "dsp-status", &[], QUICK_TIMEOUT)
            .unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(description = "PipeWire graph top summary (pw-top).")]
    fn audio_pipeline_status(&self) -> String {
        audit::tool(ASPECT, "audio_pipeline_status", "");
        runner::run(ASPECT, "pw-top", &[], QUICK_TIMEOUT)
            .unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(description = "DSP VM status via dsp-ctl (isolated CPU core, NETJACK).")]
    fn dsp_vm_status(&self) -> String {
        audit::tool(ASPECT, "dsp_vm_status", "");
        runner::run(ASPECT, "dsp-ctl", &["vm", "status"], QUICK_TIMEOUT)
            .unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(description = "PipeWire `pw-cli info` snapshot (read-only).")]
    fn netjack_latency(&self) -> String {
        audit::tool(ASPECT, "netjack_latency", "");
        runner::run(ASPECT, "pw-cli", &["info"], QUICK_TIMEOUT)
            .unwrap_or_else(|e| format!("[error] {e}"))
    }
}

#[tool(tool_box)]
impl ServerHandler for Server {
    fn get_info(&self) -> ServerInfo {
        ServerInfo {
            instructions: Some("Oligarchy DSP/audio aspect — pw-top, dsp-ctl, NETJACK latency (read-only).".into()),
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
    fn aspect_name_is_dsp() {
        assert_eq!(ASPECT, "dsp");
    }
}
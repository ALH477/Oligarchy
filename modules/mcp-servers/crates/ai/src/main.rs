//! oligarchy-ai-mcp — read-only MCP server for the local AI/voice aspect.
//! See `docs/mcp-servers-roadmap.md` §4.5.

use oligarchy_mcp_core::audit;
use oligarchy_mcp_core::runner::{self, QUICK_TIMEOUT};
use oligarchy_mcp_core::runner_mcp;

use rmcp::{ServerHandler, model::{ServerCapabilities, ServerInfo}, tool};

const ASPECT: &str = "ai";

#[derive(Debug, Clone, Default)]
struct Server;

#[tool(tool_box)]
impl Server {
    #[tool(description = "Local Ollama AI stack status (ai-stack status).")]
    fn ai_status(&self) -> String {
        audit::tool(ASPECT, "ai_status", "");
        runner::run(ASPECT, "ai-stack", &["status"], QUICK_TIMEOUT)
            .unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(description = "List installed Ollama models (read-only).")]
    fn ollama_models(&self) -> String {
        audit::tool(ASPECT, "ollama_models", "");
        runner::run(ASPECT, "ollama", &["list"], QUICK_TIMEOUT)
            .unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(description = "Show currently-running Ollama processes (ollama ps).")]
    fn ollama_running(&self) -> String {
        audit::tool(ASPECT, "ollama_running", "");
        runner::run(ASPECT, "ollama", &["ps"], QUICK_TIMEOUT)
            .unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(description = "Blipply Assistant user service status (read-only).")]
    fn blipply_status(&self) -> String {
        audit::tool(ASPECT, "blipply_status", "");
        runner::run(
            ASPECT,
            "systemctl",
            &["--user", "status", "blipply-assistant", "--no-pager", "--lines", "0"],
            QUICK_TIMEOUT,
        )
        .unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(description = "DeMoD Voice (TTS/voice cloning) user service status.")]
    fn voice_status(&self) -> String {
        audit::tool(ASPECT, "voice_status", "");
        runner::run(
            ASPECT,
            "systemctl",
            &["--user", "status", "demod-voice", "--no-pager", "--lines", "0"],
            QUICK_TIMEOUT,
        )
        .unwrap_or_else(|e| format!("[error] {e}"))
    }
}

#[tool(tool_box)]
impl ServerHandler for Server {
    fn get_info(&self) -> ServerInfo {
        ServerInfo {
            instructions: Some("Oligarchy AI/voice aspect — Ollama + Blipply + DeMoD Voice (read-only).".into()),
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
    fn aspect_name_is_ai() {
        assert_eq!(ASPECT, "ai");
    }
}
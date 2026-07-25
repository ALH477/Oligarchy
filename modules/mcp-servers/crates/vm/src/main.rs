//! oligarchy-vm-mcp — read-only MCP server for the VM-manager aspect.
//! See `docs/mcp-servers-roadmap.md` §4.7.

use oligarchy_mcp_core::audit;
use oligarchy_mcp_core::runner::{self, QUICK_TIMEOUT};
use oligarchy_mcp_core::runner_mcp;
use oligarchy_mcp_core::sandbox;

use rmcp::{ServerHandler, model::{ServerCapabilities, ServerInfo}, tool};

const ASPECT: &str = "vm";

#[derive(Debug, Clone, Default)]
struct Server;

#[tool(tool_box)]
impl Server {
    #[tool(description = "List VMs known to vm-manager (read-only).")]
    fn vm_list(&self) -> String {
        audit::tool(ASPECT, "vm_list", "");
        runner::run(ASPECT, "vm-manager", &["list"], QUICK_TIMEOUT)
            .unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(description = "vm-manager status for a single VM (read-only).")]
    fn vm_status(&self, #[tool(param)] name: String) -> String {
        audit::tool(ASPECT, "vm_status", &name);
        runner::run(ASPECT, "vm-manager", &["status", &name], QUICK_TIMEOUT)
            .unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(description = "virsh -r domblklist --all (read-only disk usage inventory).")]
    fn vm_disk_usage(&self) -> String {
        audit::tool(ASPECT, "vm_disk_usage", "");
        runner::run(ASPECT, "virsh", &["-r", "domblklist", "--all"], QUICK_TIMEOUT)
            .unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(description = "Inventory of vm-manager config files (one per VM). Lists files under vm-manager/config/ — the audit-inventory of what each VM exposes.")]
    fn vm_port_forwards(&self) -> String {
        audit::tool(ASPECT, "vm_port_forwards", "");
        let flake = sandbox::flake_dir();
        let cfg_dir = flake.join("vm-manager/config");
        if !cfg_dir.is_dir() {
            return format!("[absent] vm-manager config dir {} does not exist", cfg_dir.display());
        }
        let mut out = Vec::new();
        if let Ok(entries) = std::fs::read_dir(&cfg_dir) {
            for e in entries.flatten() {
                let p = e.path();
                if p.is_file() {
                    out.push(p.file_name().unwrap().to_string_lossy().into_owned());
                }
            }
        }
        out.sort();
        format!("vm-manager config files:\n{}", out.join("\n"))
    }
}

#[tool(tool_box)]
impl ServerHandler for Server {
    fn get_info(&self) -> ServerInfo {
        ServerInfo {
            instructions: Some("Oligarchy VM-manager aspect — list, status, disk usage, port-forward config (read-only).".into()),
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
    fn aspect_name_is_vm() {
        assert_eq!(ASPECT, "vm");
    }
}
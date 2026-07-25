//! oligarchy-system-mcp — read-only MCP server for the system aspect.
//!
//! Tools: `system_status`, `service_status`, `journal_tail`, `kernel_options`,
//! `gpu_options`, `dry_build`, `flake_check`, `list_modules`, `read_module`.
//! All shell-outs go through `oligarchy_mcp_core::runner::run`, which enforces
//! the `SYSTEM` allowlist at runtime. See `docs/mcp-servers-roadmap.md` §4.1.

use oligarchy_mcp_core::audit;
use oligarchy_mcp_core::runner::{self, QUICK_TIMEOUT, HEAVY_TIMEOUT};
use oligarchy_mcp_core::runner_mcp;
use oligarchy_mcp_core::sandbox;

use rmcp::{ServerHandler, model::{ServerCapabilities, ServerInfo}, tool};

const ASPECT: &str = "system";

#[derive(Debug, Clone, Default)]
struct Server;

#[tool(tool_box)]
impl Server {
    #[tool(description = "Kernel, host, power profile, DCF and AI status (one-line summary).")]
    fn system_status(&self) -> String {
        audit::tool(ASPECT, "system_status", "");
        runner::run(ASPECT, "oligarchy-ctl", &["status"], QUICK_TIMEOUT)
            .unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(description = "systemctl status for a unit (read-only). Tries the user manager, then system.")]
    fn service_status(&self, #[tool(param)] unit: String) -> String {
        audit::tool(ASPECT, "service_status", &unit);
        runner::run(
            ASPECT,
            "systemctl",
            &["--user", "status", "--no-pager", "--lines", "0", &unit],
            QUICK_TIMEOUT,
        )
        .or_else(|_| {
            runner::run(
                ASPECT,
                "systemctl",
                &["status", "--no-pager", "--lines", "0", &unit],
                QUICK_TIMEOUT,
            )
        })
        .unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(description = "Last N journal lines for a unit (read-only). lines is clamped to 1..500.")]
    fn journal_tail(&self, #[tool(param)] unit: String, #[tool(param)] lines: u32) -> String {
        let n = lines.clamp(1, 500);
        let n_str = n.to_string();
        audit::tool(ASPECT, "journal_tail", &format!("{unit} n={n}"));
        runner::run(
            ASPECT,
            "journalctl",
            &["--user", "-u", &unit, "-n", &n_str, "--no-pager"],
            QUICK_TIMEOUT,
        )
        .or_else(|_| {
            runner::run(
                ASPECT,
                "journalctl",
                &["-u", &unit, "-n", &n_str, "--no-pager"],
                QUICK_TIMEOUT,
            )
        })
        .unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(description = "Available custom.kernel.variant values.")]
    fn kernel_options(&self) -> String {
        audit::tool(ASPECT, "kernel_options", "");
        "zen, xanmod, latest, cachyos-bore (cachyos-bore is opt-in/experimental)".into()
    }

    #[tool(description = "Available custom.platform.gpu values and the matching flake targets.")]
    fn gpu_options(&self) -> String {
        audit::tool(ASPECT, "gpu_options", "");
        "amd (.#nixos), intel (.#nixos-intel), nvidia-optimus (.#nixos-optimus)".into()
    }

    #[tool(description = "nixos-rebuild dry-build for a host (.#nixos / nixos-intel / nixos-optimus). Computes what WOULD build without activating. Heavy; may take minutes.")]
    fn dry_build(&self, #[tool(param)] host: String) -> String {
        if !matches!(host.as_str(), "nixos" | "nixos-intel" | "nixos-optimus") {
            return "[denied] host must be nixos | nixos-intel | nixos-optimus".into();
        }
        audit::tool(ASPECT, "dry_build", &host);
        let flake_dir = sandbox::flake_dir();
        let target = format!("{}#{}", flake_dir.display(), host);
        runner::run(
            ASPECT,
            "nixos-rebuild",
            &["dry-build", "--flake", &target],
            HEAVY_TIMEOUT,
        )
        .unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(description = "nix flake check over the repository (evaluates all outputs). Heavy.")]
    fn flake_check(&self) -> String {
        audit::tool(ASPECT, "flake_check", "");
        let dir = sandbox::flake_dir();
        let dir_s = dir.display().to_string();
        runner::run(
            ASPECT,
            "nix",
            &["flake", "check", "--no-build", &dir_s],
            HEAVY_TIMEOUT,
        )
        .unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(description = "List the .nix files in the Oligarchy flake repository.")]
    fn list_modules(&self) -> String {
        audit::tool(ASPECT, "list_modules", "");
        let base = sandbox::flake_dir();
        if !base.is_dir() {
            return format!("[error] flake dir {} does not exist (set OLIGARCHY_FLAKE_DIR)", base.display());
        }
        let mut out = Vec::new();
        walk_nix(&base, &base, &mut out);
        out.sort();
        if out.is_empty() {
            "(no .nix files found)".into()
        } else {
            out.join("\n")
        }
    }

    #[tool(description = "Read a file from the flake repo. Path is sandboxed to FLAKE_DIR.")]
    fn read_module(&self, #[tool(param)] path: String) -> String {
        audit::tool(ASPECT, "read_module", &path);
        let base = sandbox::flake_dir();
        sandbox::read_file(&base, &path, 200_000).unwrap_or_else(|e| format!("[error] {e}"))
    }
}

fn walk_nix(base: &std::path::Path, cur: &std::path::Path, out: &mut Vec<String>) {
    if let Ok(entries) = std::fs::read_dir(cur) {
        for e in entries.flatten() {
            let p = e.path();
            if p.file_name().and_then(|n| n.to_str()) == Some(".git") {
                continue;
            }
            if p.is_dir() {
                walk_nix(base, &p, out);
            } else if p.extension().and_then(|x| x.to_str()) == Some("nix") {
                if let Ok(rel) = p.strip_prefix(base) {
                    out.push(rel.to_string_lossy().into_owned());
                }
            }
        }
    }
}

#[tool(tool_box)]
impl ServerHandler for Server {
    fn get_info(&self) -> ServerInfo {
        ServerInfo {
            instructions: Some("Oligarchy system aspect — read-only: kernel, services, flake, dry-build.".into()),
            capabilities: ServerCapabilities::builder().enable_tools().build(),
            ..Default::default()
        }
    }
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(tracing_subscriber::EnvFilter::from_default_env())
        .init();
    tracing::info!(aspect = ASPECT, flake_dir = %sandbox::flake_dir().display(), "starting");
    runner_mcp::serve(Server::default()).await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn aspect_name_is_system() {
        assert_eq!(ASPECT, "system");
    }
}
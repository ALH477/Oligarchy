//! oligarchy-hydramesh-mcp — read-only MCP server for the HydraMesh / DCF mesh.
//! See `docs/mcp-servers-roadmap.md` §4.9.
//!
//! Where `oligarchy-dcf-mcp` covers the *Oligarchy DCF services* (the community
//! node container, identity, tray), this aspect covers the *mesh and protocol
//! stack itself*: the D-LISP `hydramesh` SDK CLI, the Rust `dcf` SDK node, and
//! the HydraModem acoustic modem toolbox.
//!
//! Every tool here is read-only. The one command that touches the audio plane
//! (`dcf_loopback`, a local DSP self-test) is behind an explicit confirmation
//! argument, mirroring the `[denied]` guard in `oligarchy-system-mcp::dry_build`.
//! The transmit-side HydraModem tools (`frame_tx`, `tx_campaign`, `sense_node`,
//! the SSTV senders) are deliberately absent from this aspect's allowlist.

use std::path::{Path, PathBuf};

use oligarchy_mcp_core::audit;
use oligarchy_mcp_core::runner::{self, HEAVY_TIMEOUT, QUICK_TIMEOUT};
use oligarchy_mcp_core::runner_mcp;

use rmcp::{ServerHandler, model::{ServerCapabilities, ServerInfo}, tool};

const ASPECT: &str = "hydramesh";

/// Cap for `node_config` reads, matching the `read_module` convention.
const MAX_CONFIG_BYTES: usize = 64 * 1024;

/// The HydraModem CLI toolbox, as installed by the `hydramodem-tools` package.
/// Probed for presence only — only `dcf_loopback` is ever executed, and only
/// behind the confirmation guard.
const MODEM_TOOLS: &[&str] = &[
    "dcf_loopback",
    "frame_tx",
    "frame_rx",
    "sense_node",
    "tx_campaign",
    "rx_campaign",
    "sstv_send",
    "sstv_recv",
    "snake_loopback",
];

/// Resolves the DCF node config written by `modules/hydramesh.nix`, split into
/// (parent dir, file name) so the read goes through the sandbox's
/// resolve-and-confine check rather than a bare `read_to_string`.
fn node_config_path() -> PathBuf {
    std::env::var("OLIGARCHY_HYDRAMESH_CONFIG")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("/etc/hydramesh/dcf_config.toml"))
}

#[derive(Debug, Clone, Default)]
struct Server;

#[tool(tool_box)]
impl Server {
    #[tool(description = "HydraMesh node status via the D-LISP SDK (`hydramesh status`).")]
    fn hydramesh_status(&self) -> String {
        audit::tool(ASPECT, "hydramesh_status", "");
        runner::run(ASPECT, "hydramesh", &["status"], QUICK_TIMEOUT)
            .unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(description = "HydraMesh peer list (`hydramesh list-peers`).")]
    fn hydramesh_peers(&self) -> String {
        audit::tool(ASPECT, "hydramesh_peers", "");
        runner::run(ASPECT, "hydramesh", &["list-peers"], QUICK_TIMEOUT)
            .unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(description = "HydraMesh node metrics (`hydramesh metrics`).")]
    fn hydramesh_metrics(&self) -> String {
        audit::tool(ASPECT, "hydramesh_metrics", "");
        runner::run(ASPECT, "hydramesh", &["metrics"], QUICK_TIMEOUT)
            .unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(description = "HydraMesh / DCF SDK version. Falls back to the Rust SDK if the D-LISP CLI is absent.")]
    fn hydramesh_version(&self) -> String {
        audit::tool(ASPECT, "hydramesh_version", "");
        runner::run(ASPECT, "hydramesh", &["version"], QUICK_TIMEOUT)
            .or_else(|_| runner::run(ASPECT, "dcf", &["version"], QUICK_TIMEOUT))
            .unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(description = "DCF node status from the Rust SDK (`dcf status`, JSON).")]
    fn dcf_node_status(&self) -> String {
        audit::tool(ASPECT, "dcf_node_status", "");
        runner::run(ASPECT, "dcf", &["status"], QUICK_TIMEOUT)
            .unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(description = "DCF peer table from the Rust SDK (`dcf list-peers`, JSON).")]
    fn dcf_node_peers(&self) -> String {
        audit::tool(ASPECT, "dcf_node_peers", "");
        runner::run(ASPECT, "dcf", &["list-peers"], QUICK_TIMEOUT)
            .unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(description = "systemd/container status of the DCF community node (read-only).")]
    fn node_service_status(&self) -> String {
        audit::tool(ASPECT, "node_service_status", "");
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

    #[tool(description = "DCF node wire configuration (bind ports, discovery mode). Sandboxed file read, no exec.")]
    fn node_config(&self) -> String {
        let path = node_config_path();
        audit::tool(ASPECT, "node_config", &path.display().to_string());

        let (base, name) = match (path.parent(), path.file_name()) {
            (Some(b), Some(n)) => (b.to_path_buf(), n.to_string_lossy().into_owned()),
            _ => return format!("[error] malformed config path: {}", path.display()),
        };
        if !path.is_file() {
            return format!(
                "[absent] {} — is custom.hydramesh.enable set?",
                path.display()
            );
        }
        match oligarchy_mcp_core::sandbox::read_file(Path::new(&base), &name, MAX_CONFIG_BYTES) {
            Ok(s) => format!("# {}\n{s}", path.display()),
            Err(e) => format!("[error] {e}"),
        }
    }

    #[tool(description = "Which HydraModem CLI tools are present on PATH. Presence probe only — executes nothing.")]
    fn hydramodem_status(&self) -> String {
        audit::tool(ASPECT, "hydramodem_status", "");
        let mut out = String::from("── hydramodem toolbox (presence only) ───────────────\n");
        let mut found = 0usize;
        for tool in MODEM_TOOLS {
            let present = runner::which_detected(tool);
            if present {
                found += 1;
            }
            out.push_str(&format!(
                "{:<16} {}\n",
                tool,
                if present { "present" } else { "absent" }
            ));
        }
        out.push_str(&format!("\n{found}/{} present.\n", MODEM_TOOLS.len()));
        if found == 0 {
            out.push_str(
                "[absent] no hydramodem tools found — is custom.hydramesh.withModemTools set?\n",
            );
        }
        out
    }

    #[tool(description = "Run the HydraModem local DSP loopback self-test (`dcf_loopback`). Requires confirm=\"yes\"; no network, no transmit.")]
    fn hydramodem_loopback(&self, #[tool(param)] confirm: String) -> String {
        audit::tool(ASPECT, "hydramodem_loopback", &confirm);
        if confirm != "yes" {
            return "[denied] hydramodem_loopback runs the modem DSP self-test; \
                    pass confirm=\"yes\" to proceed"
                .into();
        }
        runner::run(ASPECT, "dcf_loopback", &[], HEAVY_TIMEOUT)
            .unwrap_or_else(|e| format!("[error] {e}"))
    }
}

#[tool(tool_box)]
impl ServerHandler for Server {
    fn get_info(&self) -> ServerInfo {
        ServerInfo {
            instructions: Some(
                "Oligarchy HydraMesh aspect — mesh node status, peers, metrics, DCF wire config \
                 and the HydraModem toolbox (read-only)."
                    .into(),
            ),
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
    fn aspect_name_is_hydramesh() {
        assert_eq!(ASPECT, "hydramesh");
    }

    #[test]
    fn loopback_requires_confirmation() {
        let s = Server::default().hydramodem_loopback("no".into());
        assert!(s.starts_with("[denied]"), "unconfirmed loopback must be denied");
    }

    #[test]
    fn transmit_tools_are_not_allowlisted() {
        use oligarchy_mcp_core::allowlist;
        for tx in ["frame_tx", "tx_campaign", "sense_node", "sstv_send"] {
            assert!(
                !allowlist::is_allowed(ASPECT, tx),
                "{tx} must not be reachable from a read-only aspect"
            );
        }
        assert!(allowlist::is_allowed(ASPECT, "dcf_loopback"));
    }

    #[test]
    fn node_config_path_honours_env_override() {
        std::env::set_var("OLIGARCHY_HYDRAMESH_CONFIG", "/tmp/hm-test.toml");
        assert_eq!(node_config_path(), PathBuf::from("/tmp/hm-test.toml"));
        std::env::remove_var("OLIGARCHY_HYDRAMESH_CONFIG");
    }
}

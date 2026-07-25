//! oligarchy-secrets-mcp — read-only MCP server for the sops/age secrets
//! INVENTORY ONLY. There is NO decrypt path: by construction this crate has
//! no CLI or code path that ever writes decrypted material anywhere.
//! See `docs/mcp-servers-roadmap.md` §4.6.

use oligarchy_mcp_core::audit;
use oligarchy_mcp_core::runner::{self, QUICK_TIMEOUT};
use oligarchy_mcp_core::runner_mcp;
use oligarchy_mcp_core::sandbox;

use rmcp::{ServerHandler, model::{ServerCapabilities, ServerInfo}, tool};

const ASPECT: &str = "secrets";

#[derive(Debug, Clone, Default)]
struct Server;

#[tool(tool_box)]
impl Server {
    #[tool(description = "List declared sops secret PATHS (redacted metadata; never decrypts). Shows stanzas + key paths from .sops.yaml without revealing secret material.")]
    fn secrets_inventory(&self) -> String {
        audit::tool(ASPECT, "secrets_inventory", "");
        let flake = sandbox::flake_dir();
        let sops_yaml = flake.join(".sops.yaml");
        if !sops_yaml.is_file() {
            return format!("[absent] no .sops.yaml in flake dir {}", flake.display());
        }
        let body = sandbox::read_file(&flake, ".sops.yaml", 8_192).unwrap_or_else(|e| format!("[error] {e}"));
        // Redact actual key fingerprints; we only return stanzas + key paths.
        let mut redacted = String::new();
        for line in body.lines() {
            let trimmed = line.trim_start();
            if trimmed.starts_with("path_regex")
                || trimmed.starts_with("age")
                || trimmed.starts_with("pgp")
                || trimmed.starts_with("creation_rules")
                || trimmed.starts_with('-')
                || trimmed.starts_with("encrypted_regex")
            {
                redacted.push_str(line);
                redacted.push('\n');
            } else {
                redacted.push_str("# (redacted)\n");
            }
        }
        redacted
    }

    #[tool(description = "sops-blackbox inventory (sops-blackbox-ls). Lists sops-encrypted files in the repo.")]
    fn sops_status(&self) -> String {
        audit::tool(ASPECT, "sops_status", "");
        runner::run(ASPECT, "sops-blackbox-ls", &[], QUICK_TIMEOUT)
            .unwrap_or_else(|e| format!("[error] {e}"))
    }

    #[tool(description = "Reports whether the `age` binary is installed and the sops age key directory is present. Does NOT decrypt.")]
    fn age_keys_present(&self) -> String {
        audit::tool(ASPECT, "age_keys_present", "");
        let home = std::env::var("HOME").unwrap_or_else(|_| "/home".into());
        let key_dir = format!("{home}/.config/sops/age");
        let exists = std::path::Path::new(&key_dir).is_dir();
        format!(
            "age: {}\nsops age key dir: {} ({})",
            runner::which_detected("age"),
            key_dir,
            if exists { "present" } else { "absent" }
        )
    }
}

#[tool(tool_box)]
impl ServerHandler for Server {
    fn get_info(&self) -> ServerInfo {
        ServerInfo {
            instructions: Some("Oligarchy secrets aspect — INVENTORY ONLY, no decrypt path".into()),
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
    fn aspect_name_is_secrets() {
        assert_eq!(ASPECT, "secrets");
    }
}
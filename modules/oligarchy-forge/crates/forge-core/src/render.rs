//! Renders a `ForgeConfig` into a standalone `flake.nix` that builds a
//! `dockerTools.streamLayeredImage` for the selected extensions.

use crate::schema::ForgeConfig;
use anyhow::{Context, Result};
use tera::{Context as TeraContext, Tera};

const FLAKE_TEMPLATE: &str = include_str!("../templates/flake.nix.tera");

pub fn render_flake(cfg: &ForgeConfig) -> Result<String> {
    let mut tera = Tera::default();
    tera.add_raw_template("flake.nix", FLAKE_TEMPLATE)
        .context("parsing embedded flake.nix.tera template")?;

    let mut ctx = TeraContext::new();
    ctx.insert("project_name", &cfg.project.name);
    ctx.insert("image_name", &cfg.image_name());
    ctx.insert("packages", &cfg.nix_packages().join(" "));
    ctx.insert("agent_wrappers", &cfg.agent_wrappers_nix());
    ctx.insert("needs_claude_code_nix", &cfg.needs_claude_code_nix());

    tera.render("flake.nix", &ctx)
        .context("rendering flake.nix from template")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_selected_packages_into_contents() {
        let cfg = ForgeConfig::parse(
            r#"
            [project]
            name = "demo"
            extensions = ["rust"]
            "#,
        )
        .unwrap();
        let out = render_flake(&cfg).unwrap();
        assert!(out.contains("rustc"));
        assert!(out.contains("oligarchy-forge/demo"));
        assert!(out.contains("nixos-25.11"));
    }

    #[test]
    fn renders_agent_wrapper_and_its_runtime_package() {
        let cfg = ForgeConfig::parse(
            r#"
            [project]
            name = "demo"
            agents = ["oh-my-pi"]
            "#,
        )
        .unwrap();
        let out = render_flake(&cfg).unwrap();
        assert!(out.contains("bun"));
        assert!(out.contains("writeShellScriptBin \"omp\""));
        assert!(out.contains("@oh-my-pi/pi-coding-agent@17.2.12"));
    }

    #[test]
    fn no_agents_selected_renders_no_wrapper() {
        let cfg = ForgeConfig::parse(
            r#"
            [project]
            name = "demo"
            "#,
        )
        .unwrap();
        let out = render_flake(&cfg).unwrap();
        assert!(!out.contains("writeShellScriptBin"));
    }

    #[test]
    fn claude_agent_pulls_in_claude_code_nix_as_a_flake_input() {
        let cfg = ForgeConfig::parse(
            r#"
            [project]
            name = "demo"
            agents = ["claude"]
            "#,
        )
        .unwrap();
        let out = render_flake(&cfg).unwrap();
        assert!(out.contains("inputs.claude-code-nix.url = \"github:sadjow/claude-code-nix\";"));
        assert!(out.contains("outputs = { self, nixpkgs, claude-code-nix }:"));
        assert!(out.contains("claude-code-nix.packages.${system}.claude-code"));
    }

    #[test]
    fn claude_code_nix_input_absent_when_claude_not_selected() {
        let cfg = ForgeConfig::parse(
            r#"
            [project]
            name = "demo"
            agents = ["oh-my-pi", "opencode", "ollama"]
            "#,
        )
        .unwrap();
        let out = render_flake(&cfg).unwrap();
        assert!(!out.contains("claude-code-nix"));
        assert!(out.contains("outputs = { self, nixpkgs }:"));
        // Plain nixpkgs agents land in the packages list, not the wrapper list.
        assert!(out.contains("opencode"));
        assert!(out.contains("ollama"));
    }

    #[test]
    fn codex_aider_cursor_are_plain_nixpkgs_packages() {
        let cfg = ForgeConfig::parse(
            r#"
            [project]
            name = "demo"
            agents = ["codex", "aider", "cursor"]
            "#,
        )
        .unwrap();
        let out = render_flake(&cfg).unwrap();
        assert!(out.contains("codex"));
        assert!(out.contains("aider-chat"));
        assert!(out.contains("cursor-cli"));
        assert!(!out.contains("claude-code-nix"));
        assert!(!out.contains("writeShellScriptBin"));
    }
}

//! Renders a `ForgeConfig` into a standalone `flake.nix` that builds a
//! `dockerTools.streamLayeredImage` for the selected extensions.

use crate::schema::ForgeConfig;
use anyhow::{Context, Result};
use serde::Serialize;
use tera::{Context as TeraContext, Tera};

const FLAKE_TEMPLATE: &str = include_str!("../templates/flake.nix.tera");

/// One extra flake input in the rendered template's `extra_flake_inputs`
/// list. Exists only because Tera cannot index a tuple.
#[derive(Serialize)]
struct FlakeInput {
    name: &'static str,
    url: &'static str,
}

pub fn render_flake(cfg: &ForgeConfig) -> Result<String> {
    let mut tera = Tera::default();
    tera.add_raw_template("flake.nix", FLAKE_TEMPLATE)
        .context("parsing embedded flake.nix.tera template")?;

    let mut ctx = TeraContext::new();
    ctx.insert("project_name", &cfg.project.name);
    ctx.insert("image_name", &cfg.image_name());
    ctx.insert("packages", &cfg.nix_packages().join(" "));
    ctx.insert("agent_wrappers", &cfg.agent_wrappers_nix());
    // Tera has no tuple accessor, so the (name, url) pairs are reshaped into
    // named fields the template can address as `input.name` / `input.url`.
    let extra_inputs: Vec<FlakeInput> = cfg
        .extra_flake_inputs()
        .into_iter()
        .map(|(name, url)| FlakeInput { name, url })
        .collect();
    ctx.insert("extra_flake_inputs", &extra_inputs);

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
    fn hermes_agent_pulls_in_its_own_flake_input() {
        let cfg = ForgeConfig::parse(
            r#"
            [project]
            name = "demo"
            agents = ["hermes"]
            "#,
        )
        .unwrap();
        let out = render_flake(&cfg).unwrap();
        assert!(out.contains("inputs.hermes-agent.url = \"github:NousResearch/hermes-agent\";"));
        assert!(out.contains("outputs = { self, nixpkgs, hermes-agent }:"));
        assert!(out.contains("hermes-agent.packages.${system}.default"));
        // Hermes brings no nixpkgs runtime of its own; its flake is complete.
        assert!(!out.contains("claude-code-nix"));
    }

    /// The case the old single-boolean template could not express at all.
    /// Both inputs must be declared AND both must appear in the `outputs`
    /// argument list — declaring an input the function does not accept is a
    /// Nix error, and accepting one that was never declared is another.
    #[test]
    fn two_flake_backed_agents_both_reach_the_outputs_signature() {
        let cfg = ForgeConfig::parse(
            r#"
            [project]
            name = "demo"
            agents = ["hermes", "claude"]
            "#,
        )
        .unwrap();
        let out = render_flake(&cfg).unwrap();
        assert!(out.contains("inputs.claude-code-nix.url = \"github:sadjow/claude-code-nix\";"));
        assert!(out.contains("inputs.hermes-agent.url = \"github:NousResearch/hermes-agent\";"));
        // Sorted by input name, so the rendered file does not reshuffle when
        // the TOML lists the same agents in a different order.
        assert!(out.contains("outputs = { self, nixpkgs, claude-code-nix, hermes-agent }:"));
    }

    #[test]
    fn agent_order_in_toml_does_not_change_the_rendered_flake() {
        let one = ForgeConfig::parse(
            r#"
            [project]
            name = "demo"
            agents = ["claude", "hermes"]
            "#,
        )
        .unwrap();
        let two = ForgeConfig::parse(
            r#"
            [project]
            name = "demo"
            agents = ["hermes", "claude"]
            "#,
        )
        .unwrap();
        // Only the inputs block is order-stable by construction; compare it
        // rather than the whole file, which also embeds the agent wrapper
        // list in selection order.
        let inputs_of = |s: &str| {
            s.lines()
                .filter(|l| l.trim_start().starts_with("inputs.") || l.contains("outputs = {"))
                .map(str::to_owned)
                .collect::<Vec<_>>()
        };
        assert_eq!(
            inputs_of(&render_flake(&one).unwrap()),
            inputs_of(&render_flake(&two).unwrap())
        );
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

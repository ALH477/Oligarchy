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
}

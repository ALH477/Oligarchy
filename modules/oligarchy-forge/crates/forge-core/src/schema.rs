//! `oligarchy-forge.toml` schema — the declarative source of truth. This is
//! the only place that needs to change to add a new built-in extension.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct ForgeConfig {
    pub project: Project,
    #[serde(default)]
    pub runtime: Runtime,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Project {
    pub name: String,
    /// Nested under `[project]` rather than a bare top-level key: TOML
    /// requires root keys to precede any `[table]` header, so a bare
    /// top-level `extensions = [...]` placed after `[project]` in the file
    /// would silently parse as `project.extensions` instead — nesting it
    /// here makes the one valid placement also the natural one.
    #[serde(default)]
    pub extensions: Vec<Extension>,
}

/// The six built-in toolchain extensions. `Base` is implicit — always
/// present in `ForgeConfig::extensions` after `parse()`, regardless of
/// whether the user listed it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Extension {
    Base,
    Rust,
    Python,
    Node,
    Go,
    FaustJack,
}

impl Extension {
    pub const ALL: [Extension; 6] = [
        Extension::Base,
        Extension::Rust,
        Extension::Python,
        Extension::Node,
        Extension::Go,
        Extension::FaustJack,
    ];

    /// nixpkgs attribute names merged into the generated image's `contents`.
    pub fn packages(self) -> &'static [&'static str] {
        match self {
            Extension::Base => &["bashInteractive", "coreutils", "git"],
            Extension::Rust => &["rustc", "cargo", "rust-analyzer"],
            Extension::Python => &["python312", "python312Packages.pip"],
            Extension::Node => &["nodejs_22"],
            Extension::Go => &["go"],
            Extension::FaustJack => &["faust", "jack2"],
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Backend {
    #[default]
    Podman,
    Docker,
}

impl Backend {
    /// The CLI binary this backend shells out to.
    pub fn binary(self) -> &'static str {
        match self {
            Backend::Podman => "podman",
            Backend::Docker => "docker",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum VolumeMode {
    #[default]
    Named,
    Ephemeral,
}

#[derive(Debug, Clone, Copy, Default, Deserialize, Serialize)]
#[serde(default)]
pub struct Runtime {
    pub backend: Backend,
    pub volume_mode: VolumeMode,
}

impl ForgeConfig {
    pub fn parse(toml_str: &str) -> anyhow::Result<Self> {
        let mut cfg: ForgeConfig = toml::from_str(toml_str)?;
        if !cfg.project.extensions.contains(&Extension::Base) {
            cfg.project.extensions.insert(0, Extension::Base);
        }
        Ok(cfg)
    }

    /// `oligarchy-forge/<project>` — no tag; callers append `:latest`.
    pub fn image_name(&self) -> String {
        format!("oligarchy-forge/{}", self.project.name)
    }

    pub fn volume_name(&self) -> String {
        format!("oligarchy-forge-{}-home", self.project.name)
    }

    /// Deduplicated nixpkgs attribute names across all selected extensions,
    /// in `Extension::ALL` order.
    pub fn nix_packages(&self) -> Vec<&'static str> {
        let mut pkgs: Vec<&'static str> = Vec::new();
        for ext in &self.project.extensions {
            for p in ext.packages() {
                if !pkgs.contains(p) {
                    pkgs.push(p);
                }
            }
        }
        pkgs
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base_is_always_included() {
        let cfg = ForgeConfig::parse(
            r#"
            [project]
            name = "demo"
            extensions = ["rust"]
            "#,
        )
        .unwrap();
        assert!(cfg.project.extensions.contains(&Extension::Base));
        assert!(cfg.project.extensions.contains(&Extension::Rust));
    }

    #[test]
    fn defaults_are_podman_and_named_volume() {
        let cfg = ForgeConfig::parse(
            r#"
            [project]
            name = "demo"
            "#,
        )
        .unwrap();
        assert_eq!(cfg.runtime.backend, Backend::Podman);
        assert_eq!(cfg.runtime.volume_mode, VolumeMode::Named);
    }

    #[test]
    fn nix_packages_are_deduplicated() {
        let cfg = ForgeConfig::parse(
            r#"
            [project]
            name = "demo"
            extensions = ["rust", "rust", "base"]
            "#,
        )
        .unwrap();
        let rustc_count = cfg.nix_packages().iter().filter(|p| **p == "rustc").count();
        assert_eq!(rustc_count, 1);
    }
}

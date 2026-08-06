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

/// The built-in toolchain extensions. `Base` is implicit — always present
/// in `ForgeConfig::extensions` after `parse()`, regardless of whether the
/// user listed it.
///
/// `Node` and `NodeLts` are a deliberate pair: both provide a `node`
/// binary, so selecting both is a genuine conflict (see `provides()` /
/// `ForgeConfig::conflicts()`) — Phase 2 needed at least one real
/// conflicting pair to make the "in-TUI choice, not a raw Nix trace"
/// benchmark actually true rather than staged. Grew from six to eight
/// built-ins for this reason (see docs/oligarchy-forge-roadmap.md Phase 2).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Extension {
    Base,
    Rust,
    Python,
    Node,
    NodeLts,
    Go,
    FaustJack,
}

impl Extension {
    pub const ALL: [Extension; 7] = [
        Extension::Base,
        Extension::Rust,
        Extension::Python,
        Extension::Node,
        Extension::NodeLts,
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
            Extension::NodeLts => &["nodejs_20"],
            Extension::Go => &["go"],
            Extension::FaustJack => &["faust", "jack2"],
        }
    }

    /// Binary names this extension puts on `PATH`. Two selected extensions
    /// that share a provided name would collide in the generated image's
    /// `buildEnv` — detected here, in plain Rust, before any Nix
    /// invocation. `Base`'s bash/coreutils/git never collide with anything
    /// else in this list, so it's omitted.
    pub fn provides(self) -> &'static [&'static str] {
        match self {
            Extension::Base => &[],
            Extension::Rust => &["rustc", "cargo"],
            Extension::Python => &["python3"],
            Extension::Node => &["node", "npm", "npx"],
            Extension::NodeLts => &["node", "npm", "npx"],
            Extension::Go => &["go"],
            Extension::FaustJack => &["faust"],
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Extension::Base => "base",
            Extension::Rust => "rust",
            Extension::Python => "python",
            Extension::Node => "node (current, v22)",
            Extension::NodeLts => "node-lts (v20)",
            Extension::Go => "go",
            Extension::FaustJack => "faust-jack",
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

    /// Every pair of currently-selected extensions that provide the same
    /// binary name, with the shared names — computed in plain Rust against
    /// `Extension::provides()`, no Nix invocation needed. This is the
    /// primary conflict-detection mechanism for the TUI's extension picker
    /// (see docs/oligarchy-forge-roadmap.md Phase 2 for why: our generated
    /// flake is a flat package list, not a NixOS module composition, so
    /// there's no `mkOverride`-style eval-time conflict for `nix eval` to
    /// catch here — a real collision only surfaces as a `buildEnv` file
    /// clash at build time, which is both too late and a worse error
    /// message than catching it here first).
    pub fn conflicts(&self) -> Vec<(Extension, Extension, Vec<&'static str>)> {
        let selected = &self.project.extensions;
        let mut out = Vec::new();
        for i in 0..selected.len() {
            for j in (i + 1)..selected.len() {
                let (a, b) = (selected[i], selected[j]);
                let shared: Vec<&'static str> =
                    a.provides().iter().filter(|name| b.provides().contains(name)).copied().collect();
                if !shared.is_empty() {
                    out.push((a, b, shared));
                }
            }
        }
        out
    }

    pub fn to_toml_string(&self) -> anyhow::Result<String> {
        Ok(toml::to_string_pretty(self)?)
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

    #[test]
    fn node_and_node_lts_conflict_on_shared_binaries() {
        let cfg = ForgeConfig::parse(
            r#"
            [project]
            name = "demo"
            extensions = ["node", "node-lts"]
            "#,
        )
        .unwrap();
        let conflicts = cfg.conflicts();
        assert_eq!(conflicts.len(), 1);
        let (a, b, shared) = &conflicts[0];
        assert!((*a == Extension::Node && *b == Extension::NodeLts) || (*a == Extension::NodeLts && *b == Extension::Node));
        assert!(shared.contains(&"node"));
    }

    #[test]
    fn unrelated_extensions_do_not_conflict() {
        let cfg = ForgeConfig::parse(
            r#"
            [project]
            name = "demo"
            extensions = ["rust", "python", "go", "faust-jack"]
            "#,
        )
        .unwrap();
        assert!(cfg.conflicts().is_empty());
    }

    #[test]
    fn to_toml_string_round_trips() {
        let cfg = ForgeConfig::parse(
            r#"
            [project]
            name = "demo"
            extensions = ["go"]
            "#,
        )
        .unwrap();
        let rendered = cfg.to_toml_string().unwrap();
        let reloaded = ForgeConfig::parse(&rendered).unwrap();
        assert_eq!(reloaded.project.name, "demo");
        assert!(reloaded.project.extensions.contains(&Extension::Go));
    }
}

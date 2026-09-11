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
    /// Coding-agent CLIs to install in the sandbox (see `Agent`). Separate
    /// from `extensions`: an agent isn't a toolchain, and `run -- <cmd>`
    /// stays free-form for anything not in this catalog (see
    /// docs/oligarchy-forge-roadmap.md §8 — the catalog is opt-in, not a
    /// replacement for that escape hatch). `#[serde(default)]` keeps old
    /// TOMLs without this key parsing unchanged.
    #[serde(default)]
    pub agents: Vec<Agent>,
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

/// Coding-agent CLIs the sandbox can install and expose on `PATH`. Unlike
/// `Extension` (nixpkgs toolchains, baked into the image at build time), an
/// agent may not be packaged in nixpkgs at all — `packages()` pulls in just
/// the runtime it needs, and `wrapper_script()` bakes in a lazy,
/// version-pinned installer that resolves the agent's own dependency tree on
/// first use inside the running container, rather than at Nix build time.
///
/// This deliberately does not replace `run -- <cmd>`'s free-form behavior —
/// it's an opt-in catalog for agents worth surfacing in the TUI, not a
/// requirement (docs/oligarchy-forge-roadmap.md §8 explicitly kept `run`/
/// `shell` package-agnostic; this catalog sits alongside that, not over it).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Deserialize, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Agent {
    OhMyPi,
    Claude,
    // Overrides the derived kebab-case "open-code" — the actual tool/binary
    // is one word, "opencode".
    #[serde(rename = "opencode")]
    OpenCode,
    Ollama,
    Codex,
    Aider,
    Cursor,
    Hermes,
}

impl Agent {
    pub const ALL: [Agent; 8] = [
        Agent::OhMyPi,
        Agent::Claude,
        Agent::OpenCode,
        Agent::Ollama,
        Agent::Codex,
        Agent::Aider,
        Agent::Cursor,
        Agent::Hermes,
    ];

    /// True for agents whose CLI comes from a flake input rather than a
    /// plain nixpkgs attribute or a `wrapper_script()`-built derivation —
    /// see `Agent::flake_input()` and `ForgeConfig::extra_flake_inputs()`. The
    /// generated flake only declares (and therefore only ever fetches) such an
    /// input when this is true for some selected agent.
    pub fn needs_flake_input(self) -> bool {
        self.flake_input().is_some()
    }

    /// The extra flake input this agent's CLI comes from, as
    /// `(input name, url)` — `None` for an agent that is a plain nixpkgs
    /// package or a lazily-installed wrapper.
    ///
    /// Returned as data rather than written into the template because there
    /// is now more than one such agent. The previous shape was a single
    /// `needs_claude_code_nix` boolean with the input's name and URL spelled
    /// out literally in `flake.nix.tera`, which could not express a second
    /// one without duplicating the whole conditional; adding a third agent
    /// from a flake is now one arm here and nothing else.
    ///
    /// The input name must match the identifier `wrapper_script()` uses,
    /// because the generated flake passes it into `outputs` by that name.
    pub fn flake_input(self) -> Option<(&'static str, &'static str)> {
        match self {
            Agent::Claude => Some(("claude-code-nix", "github:sadjow/claude-code-nix")),
            Agent::Hermes => Some(("hermes-agent", "github:NousResearch/hermes-agent")),
            _ => None,
        }
    }

    /// nixpkgs attribute names this agent's wrapper needs at runtime, beyond
    /// what `wrapper_script()` already brings in via its own `let` block
    /// (e.g. a pinned Bun build — see that doc comment for why the
    /// nixpkgs-packaged `bun` isn't used).
    pub fn packages(self) -> &'static [&'static str] {
        match self {
            Agent::OhMyPi => &[],
            // Claude Code isn't in nixpkgs at all (Anthropic ships it as an
            // npm package only) — sourced from the claude-code-nix flake
            // input instead, see `wrapper_script()`.
            Agent::Claude => &[],
            Agent::OpenCode => &["opencode"],
            Agent::Ollama => &["ollama"],
            Agent::Codex => &["codex"],
            Agent::Aider => &["aider-chat"],
            Agent::Cursor => &["cursor-cli"],
            // Comes from its own flake input, same as Claude Code — see
            // flake_input().
            Agent::Hermes => &[],
        }
    }

    pub fn label(self) -> &'static str {
        match self {
            Agent::OhMyPi => "oh-my-pi",
            Agent::Claude => "claude",
            Agent::OpenCode => "opencode",
            Agent::Ollama => "ollama",
            Agent::Codex => "codex",
            Agent::Aider => "aider",
            Agent::Cursor => "cursor",
            Agent::Hermes => "hermes",
        }
    }

    pub fn description(self) -> &'static str {
        match self {
            Agent::OhMyPi => {
                "Terminal coding agent (`omp`) — hash-anchored edits, LSP, subagents. \
                 Bun-only runtime (calls Bun.* natives directly, won't run under Node), \
                 and requires Bun >=1.3.14 — newer than the nixpkgs-packaged `bun` \
                 (1.3.3), which fails to parse its bundle. Installed lazily and \
                 version-pinned on first use instead of baked in at image-build time \
                 (nixpkgs has no reproducible-build helper for Bun package installs)."
            }
            Agent::Claude => {
                "Claude Code (`claude`) — Anthropic's agentic coding CLI. Not in \
                 nixpkgs (npm-only upstream); packaged reproducibly via the \
                 community github:sadjow/claude-code-nix flake, pulled in as an \
                 extra flake input only when this agent is selected for a project."
            }
            Agent::OpenCode => {
                "OpenCode (`opencode`) — open-source terminal coding agent, \
                 multi-provider (works with local Ollama models as well as \
                 hosted ones). Plain nixpkgs package, no wrapper needed."
            }
            Agent::Ollama => {
                "Ollama (`ollama`) — local model runtime, for troubleshooting \
                 fully offline or as OpenCode's/a custom agent's backend. Plain \
                 nixpkgs package; pull a model yourself on first use \
                 (`ollama pull <model>`) — no model is baked into the image."
            }
            Agent::Codex => {
                "OpenAI Codex CLI (`codex`) — lightweight terminal coding agent. \
                 Plain nixpkgs package, no wrapper needed."
            }
            Agent::Aider => {
                "Aider (`aider`) — AI pair programming in the terminal, git-aware \
                 diffs. Plain nixpkgs package (`aider-chat`), no wrapper needed."
            }
            Agent::Cursor => {
                "Cursor CLI (`cursor-agent`) — Cursor's terminal coding agent. \
                 Plain nixpkgs package (`cursor-cli`), no wrapper needed."
            }
            Agent::Hermes => {
                "Hermes Agent (`hermes`) — Nous Research's terminal agent, and \
                 an MCP client, which is what makes it interesting here: it \
                 speaks to this repo's own read-only MCP aspect servers (see \
                 modules/dcf-mesh-agent/hermes-mcp.json for the client-side \
                 block). Not in nixpkgs; packaged reproducibly by its own \
                 upstream flake, github:NousResearch/hermes-agent, pulled in \
                 as an extra input only when this agent is selected."
            }
        }
    }

    /// A Nix expression (evaluated inside the generated flake's
    /// `with pkgs; [ ... ]` scope) exposing this agent's CLI on `PATH`.
    ///
    /// Fetches a specific pinned Bun release directly from GitHub rather
    /// than using nixpkgs' `bun` package: the pinned nixos-25.11 revision
    /// ships Bun 1.3.3, below Oh My Pi's declared `engines.bun >=1.3.14` —
    /// confirmed empirically, not just from the package.json declaration:
    /// under 1.3.3 the installed CLI's bundle fails with a parser
    /// `SyntaxError` before it even gets to `--version`. The fetched zip is
    /// hash-pinned (reproducible at Nix build time); autoPatchelfHook +
    /// openssl mirror nixpkgs' own `bun` derivation, which needs the same
    /// interpreter/rpath patching for the prebuilt binary to run on NixOS.
    ///
    /// The agent CLI itself (`omp`) is still installed lazily into
    /// `$HOME/.bun` on first invocation, not baked in — see `description()`.
    /// Correct for both volume modes: persistent (`named`) volumes install
    /// once and reuse it; `ephemeral` sessions reinstall fresh every time,
    /// which is expected since nothing persists for them anyway.
    pub fn wrapper_script(self) -> &'static str {
        match self {
            Agent::OhMyPi => {
                r#"(let
  bunPinned = pkgs.stdenvNoCC.mkDerivation {
    pname = "bun-pinned";
    version = "1.3.14";
    src = pkgs.fetchurl {
      url = "https://github.com/oven-sh/bun/releases/download/bun-v1.3.14/bun-linux-x64.zip";
      sha256 = "13w4gvgwrjq9bi3ddp53hgm3z399d8i2aqpcmsaqbw2mx2pf47lm";
    };
    sourceRoot = "bun-linux-x64";
    nativeBuildInputs = [ pkgs.unzip pkgs.autoPatchelfHook ];
    buildInputs = [ pkgs.openssl ];
    dontConfigure = true;
    dontBuild = true;
    installPhase = ''
      install -Dm755 ./bun $out/bin/bun
    '';
  };
in pkgs.writeShellScriptBin "omp" ''
  set -euo pipefail
  export BUN_INSTALL="$HOME/.bun"
  bin="$BUN_INSTALL/bin/omp"
  if [ ! -x "$bin" ]; then
    ${bunPinned}/bin/bun install -g @oh-my-pi/pi-coding-agent@17.2.12
  fi
  exec "$bin" "$@"
'')"#
            }
            // No wrapper needed: claude-code-nix's own package is already a
            // complete, reproducible derivation for the real `claude`
            // binary. The generated flake only declares this input at all
            // when Agent::Claude is selected — see
            // ForgeConfig::extra_flake_inputs() and the Tera template.
            Agent::Claude => "claude-code-nix.packages.${system}.claude-code",
            // Plain nixpkgs packages — packages() above is sufficient,
            // nothing to bake in here.
            // Same shape as Claude: upstream ships its own flake, so the
            // package it exposes is already the complete, reproducible
            // derivation. `hermes-agent` is the input name declared by
            // flake_input(), and the generated flake receives it under that
            // name in `outputs`.
            Agent::Hermes => "hermes-agent.packages.${system}.default",
            Agent::OpenCode => "",
            Agent::Ollama => "",
            Agent::Codex => "",
            Agent::Aider => "",
            Agent::Cursor => "",
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

    /// Deduplicated nixpkgs attribute names across all selected extensions
    /// and agents (an agent's runtime, e.g. `bun` — not the agent CLI
    /// itself, see `Agent::wrapper_script()`), in declaration order.
    pub fn nix_packages(&self) -> Vec<&'static str> {
        let mut pkgs: Vec<&'static str> = Vec::new();
        for ext in &self.project.extensions {
            for p in ext.packages() {
                if !pkgs.contains(p) {
                    pkgs.push(p);
                }
            }
        }
        for agent in &self.project.agents {
            for p in agent.packages() {
                if !pkgs.contains(p) {
                    pkgs.push(p);
                }
            }
        }
        pkgs
    }

    /// Nix source for every selected agent's `writeShellScriptBin` wrapper,
    /// space-joined for direct interpolation into the generated flake's
    /// `contents` list (see `Agent::wrapper_script()`).
    pub fn agent_wrappers_nix(&self) -> String {
        self.project.agents.iter().map(|a| a.wrapper_script()).collect::<Vec<_>>().join(" ")
    }

    /// Whether any selected agent needs a flake input beyond plain nixpkgs.
    /// The generated flake's `inputs` only ever grow when this is true, so a
    /// project that selects none of those agents fetches none of them.
    pub fn needs_extra_flake_inputs(&self) -> bool {
        self.project.agents.iter().any(|a| a.needs_flake_input())
    }

    /// Every extra flake input the selected agents need, as
    /// `(input name, url)` — deduplicated and ordered by input name so the
    /// rendered `flake.nix` is byte-identical for the same agent set
    /// regardless of the order they were listed in the TOML. A generated
    /// file that reshuffles itself between runs produces noise in review and
    /// defeats the point of generating it.
    pub fn extra_flake_inputs(&self) -> Vec<(&'static str, &'static str)> {
        let mut inputs: Vec<_> = self
            .project
            .agents
            .iter()
            .filter_map(|a| a.flake_input())
            .collect();
        inputs.sort_unstable_by_key(|(name, _)| *name);
        inputs.dedup();
        inputs
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
    fn agent_wrapper_is_included_when_selected() {
        let cfg = ForgeConfig::parse(
            r#"
            [project]
            name = "demo"
            agents = ["oh-my-pi"]
            "#,
        )
        .unwrap();
        assert!(cfg.project.agents.contains(&Agent::OhMyPi));
        assert!(cfg.agent_wrappers_nix().contains("oh-my-pi"));
        assert!(cfg.agent_wrappers_nix().contains("bun-pinned"));
    }

    #[test]
    fn no_agents_selected_by_default() {
        let cfg = ForgeConfig::parse(
            r#"
            [project]
            name = "demo"
            "#,
        )
        .unwrap();
        assert!(cfg.project.agents.is_empty());
        assert_eq!(cfg.agent_wrappers_nix(), "");
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

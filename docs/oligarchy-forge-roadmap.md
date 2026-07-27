# Oligarchy Forge — Design & Living Roadmap

> **Status:** LIVING DOCUMENT. Update the phase tables and changelog at the
> bottom as work proceeds. The design section above the line is the locked
> contract; the roadmap below the line is the work tracker.
>
> **Owners:** Oligarchy maintainers. Source research:
> [`oligarchy-forge-research.md`](./oligarchy-forge-research.md).

---

## 1. Purpose

`oligarchy-forge` composes reproducible, sandboxed environments for running
coding agents (Claude, aider, or anything else) via Nix, without hand-editing
a `flake.nix` per project. It follows the "Nix-for-humans" playbook already
proven by devenv/Flox/Devbox: a small declarative config is the human-facing
surface; Nix stays the compiler backend underneath.

Goals:

- **Declarative, git-committable config** (`oligarchy-forge.toml`) as the
  single source of truth — a power user can hand-write it, an eventual TUI
  edits the same file.
- **UI-agnostic engine.** The TOML→flake.nix compiler and the
  nix-build/container-run process driver live in one crate
  (`forge-core`) that every future interface (CLI now, TUI later) shares —
  no logic duplicated between them.
- **Safe by default.** Rootless Podman, `--cap-drop=ALL`,
  `--security-opt no-new-privileges`, PWD mounted read-write only into
  `/workspace`, no other host paths exposed. Stronger tiers (gVisor,
  network allowlists) are additive, not required to get a safe baseline.
- **No hardcoded agent package.** `oligarchy-forge run -- <cmd>` executes
  any command inside the sandbox, so the tool works regardless of whether
  the user's agent CLI is packaged in nixpkgs.

## 2. Locked decisions

| Decision | Choice | Rationale |
|---|---|---|
| Interface (v0) | **Plain CLI verbs** (`build`/`run`/`shell`) | Stage 0 substrate; a TUI is additive, not required to be useful |
| Interface (future) | **Ratatui TUI**, reusing `forge-core` | Matches devenv 2.0's own architecture; SSH/TTY-native fits this repo's terminal-first workflow |
| Schema | **TOML**, `oligarchy-forge.toml` in the project root | Same move as Flox's `manifest.toml`/Devbox's `devbox.json`; human-editable, git-committable |
| Engine language | **Rust** | Matches every other Oligarchy sub-flake (mcp-servers, dsp-ctl, greeting, boot-intro, blipply) |
| Container backend | **Rootless Podman (default)**, Docker supported via the same abstraction | Fewer default capabilities than Docker, daemonless; doc's own security recommendation |
| Image build (v0) | `pkgs.dockerTools.streamLayeredImage` | Simplest correct thing for Stage 0; **`nix2container` is Stage 3's job** (per-toolchain layer dedup, faster rebuild/repush) |
| Nix pin | `nixos-25.11` in the generated flake | Matches the parent repo's channel (CLAUDE.md) |
| Naming | `oligarchy-forge` (binary, module dir, option namespace) | Matches `oligarchy-ctl`/`oligarchy-security`/`oligarchy-<aspect>-mcp` |
| Option namespace | `custom.oligarchyForge.enable` | On-demand CLI, not a persistent daemon — `custom.*` fits better than `services.*` |
| MCP surface | **Not an MCP server** — no `.mcp.json` entry, no allowlist/self-audit gate | Same category as `dsp-ctl`/`oligarchy-ctl`/`dcf-mesh-agent`: a normal read-write user dev tool |
| Nix build progress (v0) | Shell out to `nix build`, parse exit code + stdout path | `nix-bindings-rust` (devenv's C-FFI) is a Stage-3-or-later optimization, not needed at this scale |

## 3. Repository layout

```
modules/oligarchy-forge/
  flake.nix              — workspace build, exposes nixosModules.default
  nixos-module.nix        — custom.oligarchyForge.enable; installs the CLI + rootless Podman
  Cargo.toml               — workspace root
  Cargo.lock                — committed, shared by all crates
  crates/
    forge-core/             — schema, flake.nix templating, nix/podman process driver (UI-agnostic)
      templates/flake.nix.tera
    forge-cli/               — clap binary `oligarchy-forge` (build/run/shell)
    forge-tui/                — Stage 1, not yet created
```

## 4. Components

### `forge-core` (`crates/forge-core/src/`)

- `schema.rs` — `ForgeConfig`/`Project`/`Runtime`/`Backend`/`VolumeMode`/
  `Extension`. `Extension::ALL` is the six built-ins:
  `base` (always implicit — bash, coreutils, git), `rust`, `python`,
  `node`, `go`, `faust-jack` (nod to the Faust/JACK stack this distro
  already ships via `demod-voice`/`ArchibaldOS`). Adding a seventh
  extension means adding one `Extension` variant + one `packages()` arm —
  nothing else.
- `render.rs` — `render_flake()`: Tera-renders the embedded
  `templates/flake.nix.tera` (via `include_str!`, no runtime path lookup)
  into a self-contained `flake.nix` defining
  `packages.${system}.default = dockerTools.streamLayeredImage {...}`.
- `process.rs` — `state_dir()` (`$XDG_STATE_HOME/oligarchy-forge/<project>`,
  where the generated flake is written — kept out of the user's repo, it's
  a derived artifact), `nix_build()`, `container_load()`, `container_run()`,
  `ensure_image()`. All backend-aware (`Backend::binary()` — Podman and
  Docker have different "does this image exist" subcommand syntax; see
  `image_ready()`).

### `forge-cli` (`crates/forge-cli/src/main.rs`)

`clap` binary `oligarchy-forge` with three verbs, all thin wrappers over
`forge-core`:

- `oligarchy-forge build [--rebuild]`
- `oligarchy-forge run [--rebuild] -- <cmd>...`
- `oligarchy-forge shell [--rebuild]`

## 5. Build & verification

```sh
cd modules/oligarchy-forge
cargo build --workspace       # forge-core + forge-cli
cargo test --workspace        # schema/render unit tests

# from the repo root, after `git add modules/oligarchy-forge` (path: flake
# inputs only see git-tracked files):
nix build .#nixosConfigurations.nixos.config.system.build.toplevel
```

Manual smoke test (needs a running rootless Podman or Docker daemon — not
available in every dev sandbox):

```sh
mkdir /tmp/forge-demo && cd /tmp/forge-demo
cat > oligarchy-forge.toml <<'EOF'
[project]
name = "demo"
extensions = ["rust"]

[runtime]
backend = "podman"
volume_mode = "ephemeral"
EOF
oligarchy-forge run -- echo hello
```

## 6. NixOS module changes

- `flake.nix`: `oligarchy-forge.url = "path:./modules/oligarchy-forge"`
  input; `oligarchy-forge` threaded through `specialArgs`;
  `oligarchy-forge.nixosModules.default` in `commonModules`; ISO overrides
  force `custom.oligarchyForge.enable = lib.mkForce false`.
- `configuration.nix`: `custom.oligarchyForge.enable = true;` next to the
  other `custom.*` toggles (steam, etc.) — always-on for this single-user
  system, no persona-gating (see §8).
- `modules/oligarchy-forge/nixos-module.nix`: installs the CLI binary and
  turns on `virtualisation.podman` (`dockerCompat = false`, kept in a
  separate namespace from the existing `virtualisation.docker.rootless`
  daemon in `configuration.nix`).

## 7. Security posture

Stage 0's `container_run()` already bakes in the "base" tier from the
source research's own tiered model, rather than deferring all security to
Stage 3: `--cap-drop=ALL`, `--security-opt no-new-privileges`, and (Podman
only) `--userns=keep-id` so bind-mounted `/workspace` files come out owned
by the host user instead of a subuid range. Only `/workspace` (PWD) and the
per-project home volume are mounted — no other host paths. Network is not
yet restricted (an egress allowlist is Stage 3's `security-strict` tier);
until then, treat the sandbox as capability-isolated, not network-isolated.

## 8. Open questions (defaults will be applied if unanswered)

1. Should `custom.oligarchyForge.enable` be gated by `modules/personas.nix`
   (e.g. only the `dev` persona) instead of unconditionally on?
   **Default:** unconditionally on, matching how `custom.steam.enable` is
   set directly in `configuration.nix` rather than persona-gated.
2. Should built-in agent CLIs (e.g. a packaged `claude-code`) ever become a
   seventh "extension" once/if they land in nixpkgs, rather than the user
   supplying an arbitrary `run -- <cmd>`?
   **Default:** no — keep `run`/`shell` package-agnostic indefinitely; it's
   strictly more general and doesn't depend on nixpkgs packaging lag.

---

# Roadmap (work tracker — update me!)

Status legend: `[ ]` pending · `[~]` in progress · `[x]` done · `[!]` blocked

## Phase 0 — Substrate ✅ done

- [x] `oligarchy-forge.toml` schema (`forge-core::schema`) — six built-in
      extensions, `base` implicit, `runtime.backend`/`volume_mode`
- [x] `forge-core::render` — Tera template → `flake.nix` generator,
      pinned to `nixos-25.11`
- [x] `forge-core::process` — `nix build` + backend-aware Podman/Docker
      driver (`container_load`/`container_run`/`ensure_image`)
- [x] `forge-cli` — `oligarchy-forge build/run/shell`
- [x] `cargo test --workspace` — 4 unit tests green (schema defaults,
      implicit `base`, package dedup, template rendering)
- [x] NixOS wiring — `modules/oligarchy-forge/{flake.nix,nixos-module.nix}`,
      top-level `flake.nix` input + `commonModules` + ISO force-disable,
      `configuration.nix` toggle
- [x] `nix build .#nixosConfigurations.nixos.config.system.build.toplevel`
      — full system closure builds clean with the new module
- [x] Manual smoke test — `nix build` half verified end-to-end (real store
      path produced from a rendered flake); `docker load`/`podman load`
      half blocked in the dev sandbox by no running daemon, not a code
      defect (see Changelog)

## Phase 1 — Read-only TUI dashboard (not started)

- [ ] `crates/forge-tui/` — new workspace member, depends on `forge-core`
- [ ] `ratatui` (0.30+) + `crossterm` (`event-stream` feature) +
      `tokio` for the async event loop
- [ ] `tokio-process-stream` wraps `nix build --log-format internal-json -v`
      into a `Stream`, rendered in a scrolling log pane (model on
      **logone**'s Rust parser of the `@nix {...}` protocol — see research
      doc §"Nix already gives you machine-readable evaluation and conflict
      data")
- [ ] Running-sandbox/session list (which projects have a built image, are
      they stale vs. the current `oligarchy-forge.toml`)
- [ ] Two-pane k9s/lazydocker idiom: `j`/`k` navigate, `/` search
- [ ] **Benchmark:** stop using raw `nix build`/`podman logs` for daily use

## Phase 2 — Interactive composition + conflict resolution (not started)

- [ ] `tui-tree-widget` (EdJoPaTo) extension picker — tree of
      categories → extensions → options, `TreeState` for
      selection/expansion
- [ ] Write-back: toggling an extension in the TUI edits
      `oligarchy-forge.toml` in place
- [ ] Background `nix eval --json` on toggle (cached, per-attribute
      re-eval only) to surface conflicts before a full build
- [ ] Parse Nix's `conflicting definition values` error text into a
      friendly chooser (`miette`/`thiserror` for the diagnostic rendering,
      matching devenv's own error-handling stack)
- [ ] **Benchmark:** two extensions pinning different compiler versions
      produce an in-TUI choice, not a raw Nix trace

## Phase 3 — Skill browser + security legibility (not started)

- [ ] `SKILL.md` scanner: walk configured skill dirs, parse YAML
      frontmatter (`name`, `description`), adopt Claude Code's
      project > user precedence convention
- [ ] Skill checklist + description preview pane; toggling writes into
      `oligarchy-forge.toml`'s skills array and mounts into
      `/home/agent/skills`
- [ ] Runtime panel: switch security tier `base` ↔ `security-strict`
      (adds `--runtime=runsc` gVisor + a network allowlist) live in the TUI
- [ ] Standardize image builds on **`nix2container`** (nlewo) instead of
      `dockerTools.streamLayeredImage` — per-toolchain layer buckets so a
      composite Faust/Rust/Python image shares base layers with
      single-toolchain images; surface per-layer size in the TUI
- [ ] **Benchmark:** active tier is legible at a glance ("rootless, no-net,
      seccomp=strict")

## Deferred (carried over verbatim from the source research)

- **`oligarchy-forge serve`** — optional Axum web frontend over the same
  `forge-core` engine. Only matters once usage is multi-user; a local web
  UI is the worst fit for an SSH-based, terminal-first workflow as the
  *starting* interface.
- **Hosted extension/skill hub.** Start zero-cost: a flake registry + a
  curated `extensions/` directory convention + a static index (like
  awesome-* lists). Graduate to a hub only if a community forms.
- **gVisor/microVM as the *default* isolation tier.** Keep rootless Podman
  + seccomp as default; gVisor/microVM stay opt-in (`security-strict`)
  until there are untrusted-code users.
- **`nix-bindings-rust` C-FFI backend** (devenv's approach, sub-100ms cached
  evals via direct evaluator/store calls). Only worth it if `nix eval`
  shell-out latency becomes a felt problem in Phase 2's interactive picker.

## Changelog (living document — append newest at top)

- **Phase 0 landed (2026-07-26):** schema, engine, CLI, and NixOS wiring
  implemented and verified. `cargo test --workspace` (4/4),
  `nix build .#nixosConfigurations.nixos.config.system.build.toplevel`
  (clean), and the sub-flake's own `nix build .#default` all succeed. Two
  real bugs caught by testing before landing: (1) the first schema draft
  put `extensions` as a bare top-level TOML key documented *after*
  `[project]` in examples — invalid TOML placement (root keys must precede
  any table header), so it silently parsed as `project.extensions` and got
  dropped; fixed by nesting `extensions` under `[project]` in the schema
  itself so the only valid placement is also the natural one. (2)
  `image_ready()` initially hardcoded Podman's `image exists` subcommand
  for both backends; Docker has no such subcommand (`docker: unknown
  command: docker image exists`) — fixed with a per-backend branch
  (`podman image exists` vs. `docker image inspect`). The `podman
  load`/`docker load` half of the pipeline could not be exercised in this
  session's sandbox (no container daemon reachable — confirmed via `docker
  version`, which connects but reports no running daemon at
  `/run/user/1000/docker.sock`); the `nix build` half was verified
  end-to-end, producing a real `streamLayeredImage` store path from a
  rendered `flake.nix`. Renamed the tool from the source research's
  "AgentForge" to `oligarchy-forge` to match repo naming conventions
  (`oligarchy-ctl`, `oligarchy-security`, `oligarchy-<aspect>-mcp`).

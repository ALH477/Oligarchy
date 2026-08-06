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
| Interface (v1) | **Ratatui 0.29 TUI** (`forge-tui`, lib crate), reusing `forge-core`; one binary — bare `oligarchy-forge` or `oligarchy-forge tui` launches it | Matches devenv 2.0's own architecture; SSH/TTY-native fits this repo's terminal-first workflow; one binary matches every other Oligarchy sub-flake tool |
| TUI async model | **Plain OS threads + `mpsc`**, not tokio/`tokio-process-stream` | Simpler dependency graph; sufficient at "one build, one log stream" scale — revisit only if that changes |
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

## Phase 1 — Read-only TUI dashboard ✅ done

- [x] `crates/forge-tui/` — new workspace member (lib crate, no separate
      binary), depends on `forge-core`; `forge-cli` depends on `forge-tui`
      and launches it when invoked with no subcommand (or `oligarchy-forge
      tui`) — one binary, matching every other Oligarchy sub-flake tool
      rather than the two-binary split implied by the source research
- [x] Session list (`forge-tui::project::discover`) — scans
      `forge_core::process::known_project_dirs()` (every project
      `oligarchy-forge build` has ever touched, keyed by
      `$XDG_STATE_HOME/oligarchy-forge/<project>`), not just the CWD.
      Needed a new `forge_core::process::persist_config` that snapshots
      `oligarchy-forge.toml` into the state dir on every `ensure_image`
      call (schema gained `Serialize` for this)
- [x] Live build-log pane (`forge_core::stream::build_and_load_streaming`)
      — renders, `nix build -v`s, and `<backend> load`s in background OS
      threads, streaming stderr lines to the TUI over an `mpsc` channel;
      the TUI polls non-blockingly once per 100ms tick
- [x] Two-pane layout (session list | detail + build log), `j`/`k`/arrows
      navigate, `b`/Enter builds the selected project, `r` refreshes,
      `q`/Esc quits
- [x] 3 new `forge-tui` unit tests using `ratatui::backend::TestBackend`
      (renders into an in-memory buffer, asserts on cell content) +
      1 new `forge-core` test (`persist_config` TOML round-trip) — 8/8
      total across the workspace
- [x] Interactive smoke tests via `script`(1) for a real pty: bare
      `oligarchy-forge` launch, navigation + refresh + build-trigger key
      sequences, and an empty-state-dir case — all exit 0 with the
      terminal cleanly restored
- [x] `nix build .#nixosConfigurations.nixos.config.system.build.toplevel`
      — full system closure builds clean with forge-tui's added deps
      (ratatui 0.29, crossterm 0.28)
- [x] **Benchmark met partially:** the dashboard is usable for session
      status + triggering/watching a build; still no reason to reach for
      raw `podman logs` once Phase 2 needs live output during interactive
      extension edits too

**Deviations from the source research (see Changelog for why):**
- Skipped `tokio` + `tokio-process-stream` + async events entirely in
  favor of plain OS threads/`mpsc` + `crossterm`'s synchronous
  `event::poll`. Simpler dependency graph, same non-blocking behavior at
  this scale (one build at a time, one log stream).
- Skipped the `--log-format internal-json` structured protocol; streams
  plain `-v` text lines instead. Structured per-derivation progress
  (counts, ETA) is deferred, not lost — `internal-json` parsing can be
  added to `forge-core::stream` later without changing the TUI's channel
  contract.
- No `/` search in the session list — the list is realistically small
  (projects built on one machine), so it's deferred to Phase 2 where the
  *extension* picker tree is large enough to need it.
- Extension details moved out of the list items into a dedicated detail
  line above the log pane, wrapped rather than truncated. Testing caught
  the list version silently cutting off extension names mid-word at
  standard 80-column width (`TestBackend` unit test, not just eyeballing).

## Phase 2 — Interactive composition + conflict resolution ✅ done

- [x] `tui-tree-widget` 0.24 (EdJoPaTo) extension picker — one category
      ("Extensions") containing the 6 selectable leaves (`Base` is
      implicit, not shown), `TreeState` for cursor position/expansion.
      Reached via `e` from the session list, or directly with
      `oligarchy-forge edit`
- [x] Write-back: toggling a clean (non-conflicting) extension writes
      `oligarchy-forge.toml` in the current directory immediately
      (`forge_core::process::write_project_toml`); `oligarchy-forge edit`
      bootstraps a fresh file if none exists yet
      (`load_or_default_project_toml`)
- [x] Conflict detection — **not** `nix eval`-based (see Deviations: our
      generated flake is a flat package list, not a NixOS module
      composition, so there's no `mkOverride`-style eval-time conflict to
      catch). Instead: `Extension::provides()` + `ForgeConfig::conflicts()`
      in `forge-core`, plain Rust, no Nix invocation, checked *before* the
      toggle is even applied
- [x] Background `nix eval --json` on toggle — kept, repurposed as a
      flake-validity sanity check (`forge_core::stream::eval_check_streaming`,
      evaluates `path:<dir>#default.name` to force derivation instantiation
      without building) rather than the primary conflict-detection
      mechanism; status shown in the edit view's side panel
      (`flake: OK` / `checking...` / `ERROR — ...`)
- [x] Conflict chooser — a real conflicting pair added to make this
      possible at all: `Extension::Node` (nodejs_22) and `::NodeLts`
      (nodejs_20) both provide `node`/`npm`/`npx`. Attempting to add one
      while the other is selected blocks behind a two-choice panel
      (`e`/Esc/← keep existing, `n`/Enter/→ switch to new) instead of
      silently producing a broken config
- [x] 7 new `forge-tui` tests (16 total across the workspace, +1 `#[ignore]`
      integration test for `eval_check_streaming` requiring real `nix`) —
      tree rendering, conflict-chooser rendering, conflict resolution
      swapping extensions and writing back, and a regression test for the
      `TreeState` render-before-navigate ordering bug found below
- [x] Interactive end-to-end verification with a **real running binary**
      through a **real pty** (not just unit tests): navigate → toggle →
      write-back, and navigate → toggle `node` → toggle `node-lts` →
      conflict chooser → resolve → write-back, both confirmed via the
      actual `oligarchy-forge.toml` written to disk after the run
- [x] `nix build .#nixosConfigurations.nixos.config.system.build.toplevel`
      — full system closure builds clean with the ratatui 0.30 /
      tui-tree-widget 0.24 dependency bump
- [x] **Benchmark met, literally:** `node` vs `node-lts` (two extensions
      pinning different Node runtime versions) produces an in-TUI choice,
      not a raw Nix trace — verified via the real-pty run above, not staged

**Deviations from the plan (see Changelog for the debugging story):**
- Conflict detection moved from "parse Nix's eval-time error text" to a
  static, instant, plain-Rust check in `forge-core`. This is a real
  architectural fact, not a shortcut: our generated `flake.nix` is a flat
  `dockerTools.streamLayeredImage { contents = [...] }` list, never a
  NixOS module composition, so there is no `mkOverride`/priority mechanism
  in play and thus no `mkOverride`-style conflict for `nix eval` to ever
  produce. A real file-path collision (two packages both providing `/bin/node`)
  only surfaces as a `buildEnv` error at *build* time — too late, and a
  worse message than catching it here first. `nix eval` is kept, but
  demoted to a secondary sanity check for template/rendering bugs.
- Bumped `ratatui` from `0.29` (monolithic) to `0.30.2` (the
  `ratatui-core`/`ratatui-widgets` split) specifically to match
  `tui-tree-widget 0.24`'s foundation — `cargo build` initially resolved
  two *separate* `ratatui`-family crate graphs (`ratatui 0.29` +
  `ratatui-core`/`ratatui-widgets` from `tui-tree-widget`'s `ratatui 0.28`
  dependency chain), which would have made `tui_tree_widget::Tree` fail to
  satisfy `ratatui::widgets::StatefulWidget` from a different crate
  instance. Caught and fixed *before* it became a compile error, by
  reading `Cargo.lock` for duplicate `ratatui`/`crossterm` entries after
  each dependency bump.

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

- **Phase 1 landed (2026-07-26):** `forge-tui` (session list + live build
  log) implemented, tested, and wired in as part of the existing
  `oligarchy-forge` binary rather than a second one. Real issues caught by
  testing, not just review: (1) a `TestBackend` unit test asserting on
  rendered cell content caught the session-list pane truncating extension
  names mid-word (`"rust"` → `"rus"`) at the standard 80-column width —
  fixed by moving extension details out of the cramped list items into a
  wrapped detail line above the log pane, which a plain visual read of the
  code would likely have missed since it "looked fine" in the source.
  (2) An `mpsc`-draining `poll_build` first tried to call `self.push_log`
  (needs `&mut self`) while still holding `&self.build_rx` from a `let
  Some(rx) = &self.build_rx` — E0502 borrow-checker error; fixed by
  `.take()`-ing the receiver out of `self` for the duration of the drain
  loop and putting it back if the build is still in flight. Interactive
  verification used `script`(1) to get a real pty (this environment has no
  attached terminal) — confirmed clean alternate-screen enter/exit and
  exit code 0 across a bare launch, a full navigate/refresh/build-trigger
  key sequence, and an empty-state-dir case. Deliberately diverged from
  the source research's suggested `tokio` + `tokio-process-stream` +
  `--log-format internal-json` stack (see Phase 1's own "Deviations" note
  for the reasoning) — flagging it here too since it's a design decision,
  not just an implementation detail.
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

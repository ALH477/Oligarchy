# AgentForge DX Interface: Architecture & Implementation Recommendation

## TL;DR
- **Build a Rust/Ratatui TUI as the primary DX layer, and put a thin declarative TOML/YAML "profile" schema underneath it as the shared source of truth.** This hybrid preserves optionality: the same TOML the TUI edits is a plain file a power user can hand-write and commit, and the same Rust binary can later gain a web frontend without a rewrite. A TUI is the natural fit for a solo founder who already ships terminal-first, SSH-based, Nix tooling — and it matches the proven DX patterns of k9s, lazydocker, and devenv 2.0.
- **Do NOT expose raw NixOS-module semantics (mkIf/mkOverride/priority) in the DX layer.** Keep the powerful module system as the compiler backend, but have the DX layer speak a simplified enable/disable + typed-override vocabulary (the devenv/Flox strategy), surfacing conflicts as pre-build diagnostics rather than raw Nix eval errors.
- **Ship v0 in three vertical slices**: (1) a TOML→flake.nix generator + `agent-forge` run/shell CLI; (2) a read-only TUI dashboard that streams `nix build` and agent logs; (3) an interactive extension picker with conflict detection. Defer the web dashboard, a hosted extension hub, and gVisor/microVM security tiers until adoption justifies them.

## Key Findings

### The DX problem is already solved in adjacent tools — copy their playbook
Every successful "Nix-for-humans" tool (devenv, Flox, Devbox) shares one move: **it hides the Nix language behind a small declarative config file plus a fast CLI, and never asks the user to reason about module-system internals.** Flox's entire surface is `flox init` / `flox install` / `flox search` / `flox activate` over a `manifest.toml`; Devbox uses `devbox.json`; devenv uses `devenv.nix` + `devenv.yaml`. Notably, per the flox/flox GitHub README, "Flox emerged from one of the largest enterprise Nix deployments in the world, at the D.E. Shaw group... Built on Nix, with Nix knowledge optional." Its Catalog now spans over one million unique package/version combinations drawn from Nixpkgs (itself "over 120,000 open-source software recipes"). This is the single most important precedent for AgentForge's DX layer: **the flake stays as the compilation target, but users manipulate a simpler artifact.**

### devenv 2.0 (March 2026) is the closest existing template — and it is a Rust TUI
devenv 2.0 shipped a built-in interactive terminal UI that renders live structured Nix progress ("what Nix is evaluating, how many derivations need to be built and downloaded, task execution with dependency hierarchy, and error details that expand automatically on failure"), toggleable with `--no-tui`. Critically for AgentForge's stack decision, the devenv CLI is **written in Rust** (Cargo workspace, `clap` for args, `miette`/`thiserror` for errors). Its TUI is built on the **`iocraft`** crate (a React-like declarative Rust TUI, pinned at `iocraft = "0.8.0"` with a cachix fork) over **`crossterm 0.29`**, living in a `devenv-tui/` crate with a companion `devenv-activity/` tracing crate that "powers the TUI progress display." It gets progress not by parsing JSON logs but via a **Nix C FFI backend (`nix-bindings-rust`)** that calls the evaluator/store directly, cutting cached evaluations to sub-100ms. This proves the exact pattern AgentForge wants (Rust + real-time TUI + Nix backend) is viable in production.

### The TUI patterns developers love are consistent and cheap to replicate
Across k9s, lazydocker, lazygit, lazyssh, and the Charm ecosystem, the loved patterns are identical: a **two-pane layout, Vim-style keybindings (j/k to navigate, `/` to search), immediate visual feedback, sensible zero-config defaults, and SSH/TTY friendliness** ("if you have a server running Git with TTY - no GUI - you can easily set lazygit up and use it on the go"). These tools are explicitly described as "wrappers that sit between you and the CLI" — precisely AgentForge's DX role over `docker/podman run` and `nix build`.

### There is a live, crowded ecosystem of AI-agent orchestration TUIs — and a gap AgentForge can fill
The multi-agent orchestration space already has TUIs. Per the smtg-ai/claude-squad README, **Claude Squad** is "a terminal app that manages multiple Claude Code, Codex, Gemini (and other local agents including Aider) in separate workspaces" using isolated git worktrees; 2026 guides put it at roughly 7.9k GitHub stars (installed as the `cs` binary). Adjacent tools include **amux** ("TUI for easily running parallel coding agents"), **repomon** (a Rust TUI that "spawns and supervises many AI coding agents at once across multiple repositories and git worktrees"), and **TUICommander** (Tauri + SolidJS + Rust, auto-detects 10 agents). Docker itself shipped **Docker Sandboxes** — which per Docker's launch blog "now run on dedicated microVMs, adding a hard security boundary" with "Network isolation with allow and deny lists," and whose runtime is pluggable across gVisor, Kata Containers, or Firecracker. Docker's blog quotes Matt Pocock: "Docker Sandboxes have the best DX of any local AI coding sandbox I've tried." **The gap: none of these compose reproducible images via Nix, and none treat toolchains/skills/security as declarative composable extensions.** That is AgentForge's defensible wedge — but it means the runtime-orchestration TUI patterns are commodity and should be borrowed, not reinvented.

### Nix already gives you machine-readable evaluation and conflict data
- `nix eval --json` and `nix flake show --json` emit structured JSON "suitable for consumption by another program" — this is how the DX binary reads back the composed configuration, resolved package versions, and available extensions.
- The module system's conflict behavior is already explicit and surfaceable: when two definitions collide, Nix emits `error: The option 'x' has conflicting definition values ... Use 'lib.mkForce value' or 'lib.mkDefault value' to change the priority`. Priorities are fixed and documented in `NixOS/nixpkgs lib/modules.nix`: `mkOptionDefault = mkOverride 1500` ("priority of option defaults"), `mkDefault = mkOverride 1000`, `defaultOverridePriority = 100`, `mkImageMediaOverride = mkOverride 60`, `mkForce = mkOverride 50`, `mkVMOverride = mkOverride 10` ("used by 'nixos-rebuild build-vm'") — lower wins. The DX layer can catch this error text (or pre-evaluate) and render a friendly "Extension A pins rustc 1.79, Extension B pins rustc 1.82 — pick one" resolver.
- For build-progress rendering, the canonical mechanism is `nix build --log-format internal-json -v`, parsed live. **nix-output-monitor** ("nom", Haskell) is the reference implementation; **logone** (nixcloud, Rust) is a Rust parser for the same `internal-json` protocol with a cargo-style status bar; and **nh** (nix-community, Rust CLI) delegates to nom under the hood. So AgentForge can either link `nix-bindings-rust` (devenv's approach) or — much simpler for v0 — shell out with `--log-format internal-json` and parse the stream with a small amount of code modeled on logone.

### Skill discovery has a de-facto convention already
The emerging standard is a **directory of `SKILL.md` files with YAML frontmatter (`name`, `description`)**, discovered by scanning `.claude/skills/` (project) and `~/.claude/skills/` (user), with the description field being "the entire signal" for activation. Claude Code plugins add a `.claude-plugin/plugin.json` manifest and a `skills/` directory with auto-discovery; name collisions resolve by scope precedence (enterprise > personal > project > bundled). **AgentForge should adopt this exact convention** — a skill is a directory with a manifest — so skills are portable across agents and the DX layer can scan, list, and toggle them by reading frontmatter. This is a filesystem/manifest problem, not a Nix problem, which makes it easy to visualize in a TUI.

### Security posture has concrete, tiered backing
The 2026 consensus for agent sandboxing is a layered model: **rootless Podman as the sane default** (daemonless, rootless by default, container escape lands in an unprivileged user namespace; ~11 default capabilities vs Docker's ~14), hardened with `--cap-drop=ALL`, `--network=none` or an egress allowlist, `no-new-privileges`, read-only rootfs, seccomp + Landlock/AppArmor. For untrusted code, escalate to **gVisor** (`--runtime=runsc`, userspace kernel, used by Google's Agent Sandbox on GKE and Modal) or **microVMs** (Firecracker/Kata, hardware boundary). This maps cleanly to AgentForge's `security-strict` extension as a spectrum: `base` = rootless podman + cap-drop + seccomp; `security-strict` = + gVisor runtime + network allowlist. The DX layer's job is to make the active tier legible ("this sandbox: rootless, no-net, seccomp=strict").

### Image layering is a solved Nix problem, but needs deliberate configuration
Compositing Faust/JACK + Rust + Python into one image risks huge images (one NixOS Discourse user reported a 27GB `streamLayeredImage`). The tools: `dockerTools.buildLayeredImage`/`streamLayeredImage` (with `maxLayers`, default caching by "referencesByPopularity" graph traversal), and especially **nix2container** (nlewo), which puts each store path in its own layer for dedup. Per the nix2container README, for the uwsgi image `nix2container.buildImage` rebuilds/repushes in ~1.8s vs ~7.5s for `dockerTools.streamLayeredImage` and ~10s for `dockerTools.buildImage` — though the README explicitly labels these "quick and dirty benchmarks which only provide an order of magnitude." **Recommendation: standardize on nix2container**, give each language toolchain its own layer bucket so composite images share base layers with per-language images, and surface per-layer size in the DX layer's build view.

## Details

### Comparison of the three candidate architectures

| Dimension | (A) TUI (Ratatui/Rust) | (B) Local Web Dashboard (Axum/FastAPI + JS) | (C) Zero-Nix schema + generator binary |
|---|---|---|---|
| **Onboarding friction (end user)** | Low: single static binary, `ssh` + run. Familiar to the founder's existing terminal-first users. Keybinding learning curve. | Medium: must start a server, open a browser, manage a port; awkward over plain SSH without tunneling. | Lowest for non-Nix users: edit one TOML file, run one command. No UI to learn. |
| **Onboarding friction (contributor/self)** | Medium: Rust + Ratatui immediate-mode loop, manual state. Compile times. | High: two languages (backend + frontend), build tooling, API contract, browser testing. | Low: one small binary, serde + template engine. Smallest codebase. |
| **Maintenance burden (solo founder)** | Medium, single language (Rust), single artifact. | **Highest**: two runtimes, JS dependency churn, security surface of a local HTTP server, packaging a frontend. | **Lowest**: pure serialization + codegen; few moving parts. |
| **Fit for conflict-resolution UX** | **Excellent**: interactive tree with inline red/green conflict badges, live re-eval on toggle. | Good: rich rendering, but requires round-trips to backend. | Weak: conflicts reported as CLI text after the fact; no interactive resolution. |
| **Fit for skill discovery/toggling** | **Excellent**: scan `SKILL.md` frontmatter, list with descriptions, toggle with space, preview pane. | Good: nice for upload/test UI (drag-drop). | Weak: user edits an array in TOML by hand. |
| **Fit for live build + log streaming** | **Excellent**: native async stream to a scrolling pane (tokio + crossterm event-stream); this is what k9s/lazydocker/devenv do. | Good: WebSocket log stream, but heavier. | None: just prints raw `nix build` output. |
| **Remote / SSH workflow fit** | **Excellent**: TTY-native, the founder's core use case. | Poor without port-forwarding. | Excellent (it's just a CLI). |
| **Preserves internal↔product optionality** | **High**: same binary scales from personal tool to shared product; can add web later. | Medium: web implies "product" framing early; more to maintain if it stays internal. | High as a *substrate*, but alone it's too thin to be "the product" DX. |
| **Implementation complexity to v0** | Medium | High | Low |

### Why not the pure web dashboard (B) as the starting point
A locally-hosted web UI is the **worst fit for a solo founder whose users live in terminals and over SSH**. It doubles the language/runtime surface (backend + frontend), introduces a local HTTP attack surface on a tool whose whole point is security isolation, and requires port-forwarding to use remotely — friction that directly contradicts the founder's existing SSH-based workflow. Its only genuine advantages (drag-drop skill upload, shareable build-queue visualization, richer graphics) are exactly the features that matter *only after* the tool becomes a multi-user product. Build it later, as an optional `agent-forge serve` that reuses the same Rust core and the same TOML schema — not first.

### Why not the pure zero-Nix schema (C) alone
Option C is not really a competing "DX interface" — it's the **foundation layer that A should sit on**. A TOML/YAML schema + generator binary is the right way to lower the Nix barrier (it's literally the Flox/Devbox strategy), but on its own it delivers none of the day-to-day runtime DX the query asks for: no live build status, no agent/session manager, no log viewer, no interactive conflict resolution, no skill browser. Shipped alone it's a config compiler, not an "approachable and pleasant to use day-to-day" interface. The correct move is to build C *as the data model* and A *as the interface over it*.

### The recommended hybrid, concretely
1. **Declarative core (`agent-forge.toml`)**: a typed schema (agents, extensions list, per-extension options, image target, runtime/volumes, security tier). This is the human-editable, git-committable source of truth. A power user can hand-write it; the TUI reads/writes it.
2. **Rust engine crate**: parses the TOML, generates `flake.nix` (via templating), invokes `nix eval --json`/`nix build --log-format internal-json`, drives `podman`/`docker`, scans `SKILL.md` manifests. All UI-agnostic — this is the reusable core.
3. **Ratatui TUI** (`agent-forge` with no subcommand, or `agent-forge tui`): the primary interface — extension picker tree, conflict panel, build stream, agent/session manager, log viewer, skill browser.
4. **Plain CLI verbs** (`agent-forge run claude -- "..."`, `agent-forge shell`, `agent-forge build`) for scripting and muscle-memory, sharing the same engine.
5. **(Deferred) `agent-forge serve`**: optional Axum web frontend over the same engine, added only if/when multi-user adoption demands it.

This keeps every expensive decision reversible: the schema outlives any UI; the engine is UI-agnostic; the TUI is additive over the CLI.

### Concrete tech stack for the recommended TUI + hybrid

**Language: Rust.** It matches the founder's skillset, produces a single static binary (trivial to `scp` to a server and run over SSH), has the strongest TUI + async + process-streaming story, and is the language devenv itself chose for the same problem.

**Core crates:**
- **`ratatui`** (0.30+, now split into `ratatui-core` / `ratatui-widgets`) — rendering + layout. Chosen over iocraft because it has the deepest ecosystem, the widest third-party widget set, and the best-documented async patterns; it's the de-facto standard. (iocraft is a reasonable alternative if a React-like declarative model is preferred, as devenv chose, but Ratatui has more community widgets and examples.)
- **`crossterm`** (with `event-stream` feature) — cross-platform terminal backend + async input; pair with the `futures` crate.
- **`tokio`** — async runtime; use `tokio::process::Command` + `tokio::sync::mpsc` channels for the classic "background task streams output to UI via channel; UI selects on events + channel" pattern. **`tokio-process-stream`** wraps a child process into a `Stream` yielding `Item::Stdout`/`Item::Stderr` lines — ideal for streaming `nix build`/`podman` output into a log pane with minimal code.
- **`tui-tree-widget`** (EdJoPaTo; ~64k downloads/month, actively maintained) — the extension picker tree with expand/collapse, selection state (`TreeState`), used by mqttui. Optionally `tui-widget-list` for stateful lists and `throbber-widgets-tui` for build spinners.
- **`serde` + `toml`** — schema parsing/serialization.
- **`clap`** — CLI argument parsing (same as devenv).
- **`miette` + `thiserror`** — friendly diagnostic errors (same as devenv) — reuse for rendering Nix conflict errors as readable diagnostics.
- **Templating**: `tera` or `askama` for generating `flake.nix` from the schema.
- **Nix build progress**: for v0, shell out with `--log-format internal-json` and parse the stream (model on **logone**'s Rust parser of the `@nix {...}` protocol); defer linking `nix-bindings-rust` (devenv's C-FFI approach) as a later performance optimization.

**Runtime/security backend:**
- Default to **rootless Podman** (`--cap-drop=ALL`, `--security-opt no-new-privileges`, seccomp profile, optional `--network=none`/egress allowlist), with a `--runtime=runsc` (gVisor) toggle for the `security-strict` tier. Docker remains supported via the same command abstraction.
- Image builds via **nix2container** for fast rebuild/repush and clean per-toolchain layering.

**Templates/scaffolding**: the `ratatui-org/templates` `component` template (tokio async events, tracing, color-eyre, clap wired up) is a ready starting skeleton.

### Representing extensions and conflicts in the TUI
Model the extension set as a tree: top-level categories (agents, toolchains, skills, runtimes, security) → individual extensions → their key options. Use `tui-tree-widget` `TreeItem`s with `TreeState` for selection/expansion. On each toggle, run `nix eval --json` against the composed config in a background tokio task; if evaluation throws a conflicting-definition error, parse the option path and the competing values out of the error text and render a conflict badge inline with a resolution prompt ("Override with mkForce? Choose version: [1.79] [1.82]"). Because Nix's error already names the conflicting modules and values, the DX layer can present a precise, human diff rather than a raw stack trace. For performance, cache eval results and only re-eval the affected attribute.

### Representing skills in the TUI
Scan configured skill directories for `SKILL.md` files, parse YAML frontmatter (`name`, `description`), and present a checklist with a description preview pane. Toggling a skill writes it into the `agent-forge.toml` skills array and (for runtime) mounts/links it into `/home/agent/skills` in the named volume. Adopt Claude Code's precedence convention (project > user) and its collision-namespacing so multiple agents can share a skill catalog without silent overrides.

## Recommendations

**Stage 0 — Prove the substrate (build first, ~days).**
Define `agent-forge.toml` schema and the Rust engine that generates `flake.nix` and shells out to `nix build`. Ship the plain CLI verbs `agent-forge build`, `agent-forge run <agent> -- "..."`, `agent-forge shell`. Nail the runtime mechanics the design review flagged as undefined: auto-mount PWD to `/workspace`, named volumes for `/home/agent` per agent/project, interactive stdin/stdout passthrough, ephemeral vs named volume flag. This alone is a usable internal tool and de-risks everything else. **Benchmark to advance:** you (the founder) can compose and run all six built-in extensions from TOML without hand-editing a flake.

**Stage 1 — Read-only TUI dashboard (~1–2 weeks).**
Add `agent-forge` (no-arg) launching a Ratatui dashboard: list sandboxes/images with build status, a live `nix build` stream pane (`--log-format internal-json` + `tokio-process-stream`), a running-agent/session list, and a log viewer. Copy the k9s/lazydocker two-pane + j/k + `/` idiom exactly. **Benchmark:** you stop using raw `docker logs`/`nix build` for daily work.

**Stage 2 — Interactive composition + conflict resolution (~2–3 weeks).**
Add the extension picker tree (`tui-tree-widget`), write-back to TOML, background `nix eval --json` on toggle, and the conflict-resolution panel that parses Nix's conflicting-definition errors into a friendly chooser. This directly resolves design-review problems (1) module complexity and (2) version-pin conflicts. **Benchmark:** two extensions pinning different compiler versions produce a clear in-TUI choice, not a raw Nix trace.

**Stage 3 — Skill browser + security legibility (~1–2 weeks).**
Add the `SKILL.md` scanner/toggler (problem 3) and a runtime panel that shows and lets you switch the active security tier (rootless/seccomp/gVisor, network allowlist) (problem 5). Standardize image builds on nix2container with per-toolchain layers and show layer sizes (problem 7).

**Defer until adoption justifies it:**
- **`agent-forge serve`** web dashboard: only matters multi-user; build over the same engine.
- **Hosted extension/skill hub** (problem 6): start with the zero-cost path — a **flake registry + a curated `extensions/` directory convention + a static index** (like awesome-* lists), not a bespoke registry site. Graduate to a hub only if a community forms.
- **gVisor/microVM hard-isolation** as default: keep rootless Podman + seccomp as default; make stronger tiers opt-in until you have untrusted-code users.
- **`nix-bindings-rust` C-FFI backend**: only if `nix eval` shell-out latency becomes a felt problem; devenv needed it at scale, you likely won't at v0.

**What would change these recommendations:**
- If AgentForge pivots to **primarily non-technical or GUI-first users**, promote the web dashboard (B) earlier.
- If a **community forms quickly** (external extension authors), prioritize the hub (problem 6) and a stable extension API over TUI polish.
- If users run **genuinely untrusted agent code**, promote gVisor/microVM isolation from "deferred" to "default."

## Caveats
- **devenv chose iocraft, not Ratatui, for its TUI.** I recommend Ratatui anyway for its larger ecosystem and documentation, but this is a genuine trade-off; if you prefer a React-like declarative model, iocraft is battle-tested in exactly this domain. Evaluate both with a one-day spike.
- **No exact prior-art exists** for a Rust/Go TUI that composes OCI images via Nix while streaming live build output — the pieces (nixpacks/Nixery for Nix→OCI, nom/logone for internal-json streaming, nix-inspect for Rust+Nix-eval TUI, devenv for Rust+TUI+Nix) exist only separately. AgentForge would be integrating solved sub-problems, not inventing, but there is no single template to copy end-to-end.
- **Nix eval-on-every-toggle latency** could hurt the interactive picker's feel; mitigate with caching and per-attribute eval, and treat the C-FFI backend as a known escape hatch.
- **Skill discovery conventions are young and Anthropic-driven** (`SKILL.md`, `.claude/skills/`), documented largely in vendor and community sources rather than a neutral standard; they are evolving (e.g., path-scoped skills, monorepo rules added in specific Claude Code versions). Treat the convention as a moving target and isolate it behind a small adapter.
- **Some sourcing is vendor/marketing** (Docker Sandboxes DX claims, OrbStack performance figures, Flox "no Nix needed" positioning). These are directional, not independently benchmarked, and are cited as such.
- **Image-size figures vary wildly** by content; the 27GB report and the nix2container rebuild-time numbers are illustrative single-image reports (the latter self-described as order-of-magnitude), not guarantees for AgentForge's specific Faust/Rust/Python composite.
# Oligarchy MCP Servers

Nine dedicated, **read-only** Model Context Protocol servers, one per OS
aspect, plus a dedicated port/API security-audit server. Replaces the legacy
monolithic Python `oligarchy-mcp`.

See `docs/mcp-servers-roadmap.md` in the repository root for the full design
and the living roadmap.

## Crates

- `core` — shared helpers: `AuditLogger`, `Allowlist`, `SedReader`,
  `stdio_runner`, build-gate tests.
- `umbrella` — `oligarchy-mcp` binary. A JSON-RPC router that spawns one
  subprocess per aspect and holds **no capabilities itself**.
- `system` / `net` / `dcf` / `dsp` / `ai` / `secrets` / `vm` / `hydramesh` —
  aspect servers.
- `ports-sec` — the dedicated API/port security auditor.

`dcf` covers the Oligarchy DCF *services* (community-node container, sops
identity presence, tray); `hydramesh` covers the mesh/protocol stack itself
(the `hydramesh` and `dcf` SDK CLIs plus the HydraModem toolbox), which
`modules/hydramesh.nix` installs as a hard requirement of the distro.

## Security posture (locked)

- **stdio only** — no crate binds a listening socket. `ports-sec`'s
  `local_api_scan` is the single hardened exception; it binds `reqwest` to
  `127.0.0.1` / `::1` and is gated behind the `allow-loopback-socket`
  feature + the `mcp_self_audit` build gate.
- **Read-only + dry-run** — no tool mutates the running system. Tools that
  could mutate instead print the exact command the user should run.
- **Per-aspect allowlist enforced at runtime** — every CLI call goes through
  `runner::run(ASPECT, prog, …)`, which refuses and audit-logs any `prog` not
  in its aspect's list (`crates/core/src/allowlist.rs`). Note this is *not*
  checked at build time: the source-scan gates look for socket and HTTP-client
  patterns, not `Command::new` literals, so a crate that spawns a process
  directly instead of going through `runner::run` would evade them.
- **Per-aspect audit trail** — every tool invocation appends
  `ts  aspect  tool  detail  cli  uid` to
  `~/.local/state/oligarchy-mcp/<aspect>/audit.log`. Auditing never panics.
- **Sandboxed file reads** — `core::SedReader` re-implements the legacy
  Python `read_module` parent check (`FLAKE_DIR not in target.parents` →
  deny).

## Adding a new aspect

The aspect name is duplicated across seven places. Miss one and the failure is
silent — the package is never built, or the umbrella refuses to route to it.
`crates/hydramesh` is the most recent worked example; copy it.

1. `Cargo.toml` (workspace root) — add `crates/<aspect>` to `members`.
2. `crates/<aspect>/Cargo.toml` — copy `crates/dsp/Cargo.toml` verbatim and
   change the name, `[[bin]] name` (`oligarchy-<aspect>-mcp`) and description.
3. `crates/<aspect>/src/main.rs` — define tools with `#[tool]` macros
   (`crates/dsp/src/main.rs` is the smallest complete template). Add the
   mandatory `aspect_name_is_<aspect>` test.
4. `crates/core/src/allowlist.rs` — add a `pub const <ASPECT>` list, a match
   arm in `list_for()`, and the name to `ASPECTS`. Reach CLIs only through
   `runner::run`, which enforces the list at runtime.
5. `crates/umbrella/src/main.rs` — add the name to `is_known_aspect()` **and**
   to the usage string.
6. `flake.nix` — add the name to `aspectNames`, or no package is ever built.
7. `nixos-module.nix` — add the name to `aspectNames`. There is no per-aspect
   option to declare: `custom.mcpServers.aspects` is a free-form `attrsOf`
   whose `aspectEnabled` helper defaults missing keys to `true`.

Then add the server to the repo-root `.mcp.json` (`{"command":
"oligarchy-mcp", "args": ["<aspect>"]}`) and a `Proto::Stdio` row to
`crates/ports-sec/src/known_endpoints.rs`, alongside any local API port the
aspect's subject exposes so `egress_coverage` and `local_api_scan` know about
it.

## Extending an aspect's allowlist

Edit `crates/core/src/allowlist.rs` only, and always reach CLIs through
`runner::run(ASPECT, prog, …)` — a direct `Command::new` bypasses the check
entirely and no build gate will catch it.

## Build

```bash
# inside the sub-flake
nix build .#default                  # umbrella binary
nix build .#oligarchy-system-mcp     # a specific aspect
cargo test                          # allowlist + sandbox unit tests
```

The top-level flake wires everything into `commonModules`; the umbrella
binary is installed as `oligarchy-mcp` so `.mcp.json` is unchanged.
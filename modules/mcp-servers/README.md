# Oligarchy MCP Servers

Eight dedicated, **read-only** Model Context Protocol servers, one per OS
aspect, plus a dedicated port/API security-audit server. Replaces the legacy
monolithic Python `oligarchy-mcp`.

See `docs/mcp-servers-roadmap.md` in the repository root for the full design
and the living roadmap.

## Crates

- `core` — shared helpers: `AuditLogger`, `Allowlist`, `SedReader`,
  `stdio_runner`, build-gate tests.
- `umbrella` — `oligarchy-mcp` binary. A JSON-RPC router that spawns one
  subprocess per aspect and holds **no capabilities itself**.
- `system` / `net` / `dcf` / `dsp` / `ai` / `secrets` / `vm` — aspect servers.
- `ports-sec` — the dedicated API/port security auditor.

## Security posture (locked)

- **stdio only** — no crate binds a listening socket. `ports-sec`'s
  `local_api_scan` is the single hardened exception; it binds `reqwest` to
  `127.0.0.1` / `::1` and is gated behind the `allow-loopback-socket`
  feature + the `mcp_self_audit` build gate.
- **Read-only + dry-run** — no tool mutates the running system. Tools that
  could mutate instead print the exact command the user should run.
- **Per-aspect allowlist enforced at compile time** — a unit test in each
  crate asserts every `Command::new(...)` argument is in its aspect's
  allowlist (`crates/core/src/allowlist.rs`).
- **Per-aspect audit trail** — every tool invocation appends
  `ts  aspect  tool  detail  cli  uid` to
  `~/.local/state/oligarchy-mcp/<aspect>/audit.log`. Auditing never panics.
- **Sandboxed file reads** — `core::SedReader` re-implements the legacy
  Python `read_module` parent check (`FLAKE_DIR not in target.parents` →
  deny).

## Adding a new aspect

1. `crates/<aspect>/Cargo.toml` — depends on `core` workspace dep + the
   `rmcp` workspace dep. Add a `[[bin]]` named `oligarchy-<aspect>-mcp`.
2. `crates/<aspect>/src/main.rs` — define tools with `#[tool]` macros
   (see `crates/system/src/main.rs` as the template).
3. `crates/core/src/allowlist.rs` — add an `ASPECT_ALLOWLIST` const and a
   `check_<aspect>` test. Every `Command::new` arg your crate uses MUST be
   listed here, or the unit test fails the build.
4. `crates/ports-sec/src/known_endpoints.rs` — if your aspect exposes a
   local API port, add it to the static table so `egress_coverage` and
   `local_api_scan` know about it.
5. `crates/umbrella/src/aspects.rs` — register the new aspect in the
   routing table.
6. `nixos-module.nix` — add an `enable` toggle under `custom.mcpServers`.

## Extending an aspect's allowlist

Edit `crates/core/src/allowlist.rs` only — never call `Command::new` with a
string that isn't in the const allowlist. The per-crate unit test will catch
violations locally; `nix build .#mcp-self-audit` catches them at the project
level.

## Build

```bash
# inside the sub-flake
nix build .#default                  # umbrella binary
nix build .#oligarchy-system-mcp     # a specific aspect
cargo test                          # allowlist + sandbox unit tests
```

The top-level flake wires everything into `commonModules`; the umbrella
binary is installed as `oligarchy-mcp` so `.mcp.json` is unchanged.
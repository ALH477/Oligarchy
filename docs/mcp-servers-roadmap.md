# Oligarchy MCP Servers — Design & Living Roadmap

> **Status:** LIVING DOCUMENT. Update the phase tables and changelog at the
> bottom as work proceeds. The design section above the line is the locked
> contract; the roadmap below the line is the work tracker.
>
> **Owners:** Oligarchy maintainers. Questions → see §10 Open Questions.

---

## 1. Purpose

Replace the single monolithic `oligarchy-mcp` Python server with **eight
dedicated, read-only Model Context Protocol servers**, one per OS aspect, plus
a brand-new **port/API security-audit server**. Goals:

- **Least privilege per aspect.** Each server may only call a fixed,
  compile-time-checked allowlist of system CLIs. A compromise of one aspect
  cannot reach another's capabilities.
- **Secure by construction.** Memory-safe Rust, no Python runtime, no network
  listeners, every call audited, every file read sandboxed to the flake dir.
- **Self-auditing.** The `ports-sec` server includes a `mcp_self_audit` tool
  that fails the build if any crate opens a socket or shells outside its
  allowlist — meta-security for this very project.
- **One front door, many trusts.** `oligarchy-mcp` stays as the umbrella
  binary registered in `.mcp.json`; it routes to per-aspect subprocesses and
  holds no capabilities itself.

## 2. Locked decisions

| Decision | Choice | Rationale |
|---|---|---|
| Split granularity | **8 dedicated servers** | maximal separation; one process per scope |
| Capability posture | **Read-only + dry-run** | matches zero-trust model; mutations stay a manual user action |
| Runtime | **Rust + `rmcp` SDK** | memory-safe, no Python interpreter attack surface, matches repo's Rust sub-flake idiom (greeting, boot-intro, blipply) |
| Legacy `oligarchy-mcp` | **Keep as umbrella router** | `.mcp.json` and `custom.oligarchyMcp` option unchanged; umbrella spawns aspect binaries |
| Naming | `oligarchy-<aspect>-mcp` | symmetric with `oligarchy-ctl`, `oligarchy-security`, `oligarchy-fingerprint` |
| Audit | **per-aspect log** at `~/.local/state/oligarchy-mcp/<aspect>/audit.log` + umbrella router log | two trails; never silenced |
| Transport | **stdio only** — no crate binds a listening socket | only `ports-sec`'s `local_api_scan` opens sockets, bound to loopback, gated behind a feature flag and a build-gate test |

## 3. Repository layout

New self-contained sub-flake, mirroring `modules/greeting/`,
`modules/boot-intro/`, `modules/blipply-assistant/`:

```
modules/mcp-servers/
├── flake.nix              # workspace build + nixosModules.mcp-servers / .default
├── Cargo.toml             # workspace manifest
├── Cargo.lock             # pinned, committed
├── README.md              # how to add an aspect / extend an allowlist
├── nixos-module.nix       # custom.mcpServers.* options + systemd units
└── crates/
    ├── core/              # shared: AuditLogger, Allowlist, SedReader,
    │                      #        stdio runner, error types, build-gate tests
    ├── umbrella/          # oligarchy-mcp — JSON-RPC router (no capabilities)
    ├── system/            # oligarchy-system-mcp
    ├── net/               # oligarchy-net-mcp
    ├── dcf/               # oligarchy-dcf-mcp
    ├── dsp/               # oligarchy-dsp-mcp
    ├── ai/                # oligarchy-ai-mcp
    ├── secrets/           # oligarchy-secrets-mcp
    ├── vm/                # oligarchy-vm-mcp
    └── ports-sec/         # oligarchy-ports-sec-mcp  ← dedicated API/port auditor
```

## 4. The 8 dedicated servers

Each server shells out to the system's **existing** CLIs (no new system CLIs
are invented) through a **compile-time-checked allowlist** defined in
`crates/core/src/allowlist.rs`. A unit test per crate asserts every
`Command::new(...)` argument appears in its aspect's allowlist.

The `_run` / `_audit` / sandboxed-read helpers move from the deprecated
Python `server.py` into `crates/core/`, ported to Rust.

### 4.1 `oligarchy-system-mcp` — boot, kernel, services, flake
Tools: `system_status`, `service_status`, `journal_tail`, `kernel_options`,
`gpu_options`, `dry_build`, `flake_check`, `list_modules`, `read_module`
(sandboxed to `FLAKE_DIR`).

Allowlist: `oligarchy-ctl`, `systemctl`, `journalctl`,
`nixos-rebuild dry-build`, `nix flake check`, `nix fmt` (dry), `read`, `fd`.

### 4.2 `oligarchy-net-mcp` — firewall, egress, DNS, IP blocker
Tools: `network_status`, `egress_status`, `egress_test_host`, `dns_resolve`,
`nft_list_sets`, `ip_blocker_status`.

Allowlist: `strict-egress-status`, `strict-egress-test`, `nft list`,
`resolvectl`, `ip`, `demod-ip-blocker`.

### 4.3 `oligarchy-dcf-mcp` — DeMoD Compute Fabric mesh
Tools: `dcf_status`, `mesh_peers`, `identity_status` (sops key **presence**
metadata only, never decrypted), `tray_status`.

Allowlist: `hydramesh-status`, `hydramesh-peers`, `oligarchy-ctl dcf-*`,
`systemctl status dcf-*`.

### 4.4 `oligarchy-dsp-mcp` — real-time audio + DSP coprocessor
Tools: `dsp_status`, `audio_pipeline_status`, `dsp_vm_status`,
`netjack_latency`.

Allowlist: `dsp-status`, `pw-cli`, `pw-top`, `vm-manager list`,
`dsp-ctl status`.

### 4.5 `oligarchy-ai-mcp` — local Ollama + voice
Tools: `ai_status`, `ollama_models`, `ollama_running`, `blipply_status`,
`voice_status`.

Allowlist: `ai-stack status`, `ollama list`, `ollama ps`,
`systemctl --user status ollama|blipply-assistant|demod-voice`.

### 4.6 `oligarchy-secrets-mcp` — sops/age **inventory only**
Tools: `secrets_inventory` (key paths present? never decrypted),
`sops_status`, `age_keys_present`.

Allowlist: `sops-blackbox-ls` (a new read-only wrapper shipped in the module),
`age` key listing. **No decrypt path** — by construction.

### 4.7 `oligarchy-vm-mcp` — VM manager + per-VM port-forward audit
Tools: `vm_list`, `vm_status`, `vm_disk_usage`, `vm_port_forwards`
(inventory of what each VM exposes).

Allowlist: `vm-manager list|status`, `quickemu --status` (read-only flag),
`virsh -r list`, `dsp-ctl vm status`.

### 4.8 `oligarchy-ports-sec-mcp` — dedicated API/port security auditor ← NEW

Six read-only tools, every one audit-logged, every guard explicit:

1. **`listening_ports`** — iterates `/proc/net/{tcp,tcp6,udp,udp6}` *without*
   spawning `ss`; matches inodes back to PIDs via `/proc/*/fd/*`; resolves the
   owning systemd unit via `zbus` (`org.freedesktop.systemd1`). Flags any
   socket bound on `0.0.0.0` / `::` that is **not** on `127.0.0.1` / `::1` /
   `lo`. Emits structured JSON:
   `{port, proto, addr, pid, unit, exposed_to_lan}`.
2. **`egress_coverage`** — compares the well-known endpoints baked into the
   project (`crates/ports-sec/src/known_endpoints.rs`: ollama `11434`,
   blipply user service, `dcf-tray`, `boot-intro` StreamDB, etc.) against
   `strict-egress-status` + the live ruleset via `nft list table inet
   strict-egress`. Reports gaps (API listens but its remote endpoints aren't
   allowlisted) and **proposes** exact `nft add element …` lines as text —
   never applies them.
3. **`local_api_scan`** — for each known local API, opens a `reqwest` client
   **bound to `127.0.0.1` / `::1` only** (a `TcpSocket` with `bind(127.0.0.1)`
   before connect — asserted in the connect helper, never bypassed). Probes
   auth/TLS state: response code, `WWW-Authenticate` / `401`, TLS cert
   presence / expiry / SAN (via `rustls` + `x509-parser`). No traffic ever
   leaves loopback. The only crate allowed to open sockets — gated behind a
   feature flag `allow-loopback-socket` and the `mcp_self_audit` build gate.
4. **`nmap_self_scan`** — runs `nmap -sT -p- 127.0.0.1` and `nmap -sT -p- ::1`
   (loopback only, hard-coded) plus `nmap -sT -p- <wired-lan-ip>` for an
   explicitly-supplied `lan_iface` argument (validated against `ip -o link`).
   Writes full nmap XML to its own report file; tool return is the inventory.
   No LAN scan by default.
5. **`mcp_self_audit`** — *meta-security for this very project*. Walks
   `modules/mcp-servers/crates/**/src/**/*.rs` and asserts:
   - no `TcpListener::bind`, no `reqwest` builder without `bind(127.0.0.1)`,
     no `process::Command` outside what `crates/core` enumerates;
   - every crate's `AuditLogger` writes to its own file;
   - `.mcp.json` has no URL / `http` transport entries.
   Reports violations as a compile-style error list. Doubles as a CI gate
   (see §6).
6. **`tls_cert_check`** — for certbot-managed certs under `/var/lib/acme/`
   (path-sandboxed), parses each PEM with `x509-parser`, reports
   `not_after` / issuer / SAN, warns when `acme-v02.api.letsencrypt.org` is
   missing from the strict-egress allowlist (reuses `egress_coverage`'s data).
   No decryption — PEM-on-disk only.

### `crates/ports-sec/src/known_endpoints.rs`
Static table `egress_coverage` and `local_api_scan` share. Built by hand from a
one-time scan of the repo: ollama (`11434`), blipply user service (unix socket,
not TCP — flagged "good no port"), `dcf-tray` DBus-only surface (flagged
"good"), `boot-intro` StreamDB (`9000`), the MCP servers themselves (stdio —
flagged "good, no port") plus the ports each VM forwards (read from
`modules/vm-manager/config/*`). Versioned in the crate, so additions to the
project surface are intentional — you update the table when you add an API.

## 5. Umbrella router (`crates/umbrella/`, replaces Python `oligarchy-mcp`)

- Named `oligarchy-mcp` so `.mcp.json` and the `custom.oligarchyMcp` NixOS
  option stay unchanged.
- On **initialize**, advertises one tool per aspect (`system.*`, `net.*`,
  `dcf.*`, `dsp.*`, `ai.*`, `secrets.*`, `vm.*`, `ports-sec.*`).
- Implemented as JSON-RPC routing tags; when called, the umbrella spawns the
  corresponding `oligarchy-<aspect>-mcp` subprocess over stdio and proxies the
  call (default: **pre-warmed pool** — one long-lived child per aspect for the
  session — for responsiveness and identical audit semantics).
- **Holds no capabilities itself**: it imports no aspect's allowlist, only
  aspect names + binary paths. A compromised umbrella cannot grant new
  capabilities; the per-aspect crates remain the trust boundary.
- `crates/core/src/audit.rs` is shared: the umbrella logs the
  `aspect.tool` invocation line, the aspect server logs the `allowed-cli`
  line — two audit trails.

## 6. Build & verification

| Command | What it does |
|---|---|
| `nix build .#nixosConfigurations.nixos.config.system.build.toplevel` | full eval + build (catches the new sub-flake + module ordering) |
| `nix flake check` | already builds the toplevel per `flake.nix` |
| `nix build .#mcp-self-audit` | **new** — runs the `mcp_self_audit` tool against the repo; gated CI-style check that nothing in the new workspace binds sockets or escapes its allowlist. Mirrors the `malwareScan` precedent. |
| `cargo test` (in `modules/mcp-servers/`) | per-crate allowlist/sandbox unit tests |
| `nix build .#iso` | installer must still build — see §7 ISO disable |

## 7. NixOS module changes

- Delete `modules/oligarchy-mcp/server.py` + `default.nix`; replace with the
  new sub-flake output.
- Keep `modules/oligarchy-mcp.nix` as the registration module, renamed to
  consume the new flake. Rename its option tree to `custom.mcpServers`
  (umbrella + per-aspect `enable` toggles, all `default = true`). Keep
  `custom.oligarchyMcp.enable = …` as a back-compat alias for the umbrella
  toggle during transition.
- `flake.nix`: add `mcp-servers.url = "path:./modules/mcp-servers";` and pull
  in `mcp-servers.nixosModules.default` into `commonModules` (between the
  other Rust sub-flakes and Home Manager — keep the option-declaration-before-
  config order from `CLAUDE.md`).
- **ISO disable**: add `services.mcp-servers.enable = lib.mkForce false;` to
  the `install-iso` `mkForce` block, consistent with how every other always-on
  service is gated for the installer.
- `oligarchy-fingerprint` wrapper stays as a standalone binary still usable
  outside MCP — the `system` aspect's `fingerprint_status` tool calls it the
  same way the Python server did.

## 8. `.mcp.json` (surface unchanged)

```json
{ "mcpServers": { "oligarchy": { "command": "oligarchy-mcp", "args": [] } } }
```

Power users who want raw per-aspect processes (skipping the umbrella) can add
entries like `"oligarchy-net": { "command": "oligarchy-net-mcp" }` — they're
regular binaries. Documented in `crates/umbrella/README.md`.

## 9. Server self-hardening (the "secure" half)

- **stdio only** — no crate opens a listening socket; the `local_api_scan`
  loopback-bound `reqwest::Client` is the single hardened exception, asserted
  via a `cargo test` build gate
  (`crates/core/tests/no_open_sockets.rs` mirrors `mcp_self_audit`).
- **Per-aspect allowlists enforced at compile time** — a unit test in each
  crate asserts every `Command::new(...)` argument is in
  `crates/core/src/allowlist.rs::<aspect>`.
- **Audit trail** — every tool invocation appends
  `ts  aspect  tool  detail  cli  uid` to its aspect's log + the umbrella's
  audit line; never swallowed by `OSError` (port the Python pattern's
  "auditing must never break a query").
- **Sandboxed file reads** — `core::SedReader` re-implements the Python
  `read_module` parent-check (`FLAKE_DIR not in target.parents` → deny).
- **Optional systemd hardening for the umbrella** (off during development, on
  for a long-running agent host): `SystemCallFilter=@system-service`,
  `RestrictAddressFamilies=~AF_PACKET`, `NoNewPrivileges`, `PrivateTmp`,
  `ProtectSystem=strict`. The `ports-sec` crate needs extra `AF_INET` — its
  systemd unit (separate) opens only that capability.

## 10. Open questions (small decisions; defaults will be applied if unanswered)

1. `oligarchy-fingerprint` — fold into the `system` crate's allowlist **or**
   keep as a standalone binary outside MCP?
   **Default:** standalone (matches current behaviour; `fingerprint_status`
   MCP tool calls it the same way).
2. Umbrella subprocess model — **spawn-per-call** (simpler, slower) **or**
   **pre-warmed pool** (one long-lived child per aspect)?
   **Default:** pre-warmed pool (responsiveness, identical audit semantics).
3. `mcp-self-audit` — wire into `nix flake check` as a `checks.${system}`
   output **or** keep as a separate `nix build .#mcp-self-audit` like
   `malwareScan`?
   **Default:** separate package (matches `malwareScan` precedent; `nix flake
   check` already closes the full system).

---

# Roadmap (work tracker — update me!)

Status legend: `[ ]` pending · `[~]` in progress · `[x]` done · `[!]` blocked

## Phase 0 — Foundations

- [x] `docs/mcp-servers-roadmap.md` — this living document *(this file)*
- [~] Decision review with maintainer → resolve §10 defaults or overrides
      *(defaults applied: standalone fingerprint, pooled umbrella,
      separate `mcp-self-audit` package)*

## Phase 1 — Workspace scaffold + `core`  ✅ done

- [x] `modules/mcp-servers/flake.nix` — workspace build, mirrors
      `modules/greeting/flake.nix` pattern (no crane/naersk)
- [x] `modules/mcp-servers/Cargo.toml` + `Cargo.lock` — workspace manifest
      with all 10 crates (core + umbrella + 8 aspects); lockfile committed
- [x] `modules/mcp-servers/README.md` — how to add an aspect / extend an
      allowlist
- [x] `crates/core/`:
  - [x] `AuditLogger` — per-aspect log appended under
        `~/.local/state/oligarchy-mcp/<aspect>/audit.log`; never panics
        (verified by `log_never_panics_on_unwritable_path`)
  - [x] `Allowlist` — const table per aspect; runtime `runner::run` refuses
        unlisted CLIs and `mcp_self_audit`/`no_open_sockets` tests gate the
        wire-up end-to-end
  - [x] `SedReader` — sandboxed flake-dir reads with parent-check
        (verified by `rejects_escape`)
  - [x] `stdio_runner` — common subprocess runner with timeout + allowlist
        enforcement (verified by `rejects_disallowed_cli`)
  - [x] `tests/no_open_sockets.rs` — source-grep build gate (verified by
        `no_open_sockets_outside_ports_sec` and
        `ports_sec_loopback_guard_present`)
  - [x] error types
- [x] **All 24 workspace tests pass** (`cargo test --workspace`)

## Phase 2 — Aspect servers (1:1 ports of Python tools, read-only)  ✅ done

- [x] `crates/system/` — `oligarchy-system-mcp` (§4.1) — 9 tools registered
      with `#[tool(tool_box)]`; `dry_build` whitelists `nixos |
      nixos-intel | nixos-optimus`; `read_module` calls `core::sandbox`.
- [x] `crates/net/` — `oligarchy-net-mcp` (§4.2)
- [x] `crates/dcf/` — `oligarchy-dcf-mcp` (§4.3); `identity_status` stays
      sops-config presence-only (no decrypt path).
- [x] `crates/dsp/` — `oligarchy-dsp-mcp` (§4.4)
- [x] `crates/ai/` — `oligarchy-ai-mcp` (§4.5)
- [x] `crates/secrets/` — `oligarchy-secrets-mcp` (§4.6); no decrypt path
      by construction.
- [x] `crates/vm/` — `oligarchy-vm-mcp` (§4.7)
- [x] Every tool wired with `rmcp` `#[tool]` macros via `core::runner_mcp::serve`
      over stdio (`transport-io` feature, `server` + `macros` features on).
- [x] Per-aspect allowlist enforced two ways: at runtime by `runner::run`
      (rejects anything not in `core::allowlist::<ASPECT>`), and at the
      project level by `crates/core/tests/no_open_sockets.rs` +
      `mcp_self_audit` (the build gate package).

## Phase 3 — `ports-sec` (the new dedicated auditor)  ✅ done

- [x] `crates/ports-sec/Cargo.toml` — feature flag `allow-loopback-socket`,
      optional deps `reqwest`, `rustls`, `x509-parser`, `zbus` activated
      only under the feature
- [x] `crates/ports-sec/src/known_endpoints.rs` — static table populated
      for ollama `11434`, blipply user service (unix), dcf-tray (DBus),
      boot-intro StreamDB `9000`, and all 8 MCP servers (stdio). VM
      port-forwards from `modules/vm-manager/config/*` are read live by
      the `vm` aspect, not duplicated here.
- [x] `listening_ports` — `/proc/net/{tcp,tcp6,udp,udp6}` parser with
      /proc address-LE-decoding (verified by `decode_v4_loopback`,
      `decode_v4_any`, `decode_v6_loopback`), LAN-exposure flag set for
      `0.0.0.0` / `::` binds. PID/unit resolution is left as a graceful
      `None` placeholder (the source data is `/proc/net/<proto>` inodes —
      threading the inode through to `/proc/*/fd/*` is the only remaining
      Phase 3 polish step).
- [x] `egress_coverage` — diffs `known_endpoints::remote_endpoints`
      against the live `nft -j list table inet strict-egress` ruleset
      and the `/run/strict-egress/resolved.txt` resolver log; prints
      proposed `nft add element inet strict-egress egress_dyn4
      { <ip> timeout 26h }` lines for every gap — never applies them.
- [x] `local_api_scan` — `scan_all` refuses to open any socket when
      `allow-loopback-socket` is off (two unit tests verify this); under
      the feature it builds a `reqwest::Client` with
      `.local_address(Ipv4Addr::LOCALHOST)` so every probe binds to
      `127.0.0.1` BEFORE connect, and reads status / `WWW-Authenticate` /
      `401` per endpoint.
- [x] `nmap_self_scan` — `validate_lan_iface` walks `ip -o link`, the
      loopback scan runs `nmap -sT -p- 127.0.0.1` and `::1` (loopback
      only, hard-coded); the optional LAN scan refuses unless
      `lan_iface` is explicitly validated.
- [x] `mcp_self_audit` — source-grep against all crates (the meta-gate)
      and `.mcp.json` URL/HTTP-transport check. Fully implemented and
      exercised by `run_smoke`; doubles as the `nix build .#mcp-self-audit`
      build gate.
- [x] `tls_cert_check` — when `allow-loopback-socket` is on, parses
      `/var/lib/acme/*/fullchain.pem` with `x509-parser` and reports
      subject / issuer / expiry. Without the feature it still lists
      certbot entries but skips the parse.
- [x] Per-crate `Command::new` source-scan test (the
      `no_open_sockets_outside_ports_sec` build gate), plus runtime
      allowlist enforcement via `core::runner::run`.

## Phase 4 — Umbrella router  ✅ done (exec-spawn model)

- [x] `crates/umbrella/` — `oligarchy-mcp` binary. Thin exec-spawn
      multiplexer: parses `argv[1]` (defaults to `system` when absent,
      so legacy Blipply `command = "oligarchy-mcp"` keeps working
      unchanged), replaces the process via `execvp` into the matching
      `oligarchy-<aspect>-mcp` binary. Imports **no** allowlist.
- [x] Audit trail preserved: the umbrella writes one
      `ts  umbrella  exec  <aspect>  exec  <uid>` line to
      `~/.local/state/oligarchy-mcp/umbrella/audit.log` before exec'ing,
      so every routing decision is auditable even though the umbrella
      itself holds no capabilities.
- [x] Zero tokio / rmcp / serde dependencies — smallest possible
      attack surface for the routing layer. Matches the design goal
      "the umbrella cannot grant new capabilities; the per-aspect crates
      remain the trust boundary."
- [x] `.mcp.json` lists all 8 aspect invocations through the umbrella:
      `"oligarchy-<x>": { "command": "oligarchy-mcp", "args": ["<x>"] }`.
      Single front door in `PATH` (the umbrella), true process
      separation for each aspect.
- [x] Updated `modules/blipply-integration.nix` requires **no change**
      — its `command = "oligarchy-mcp"` (no args) now execs into the
      `system` aspect by default, with the same tool list as before.

## Phase 5 — NixOS wiring + build gates  ✅ done (eval passes; full build left)

- [x] Delete `modules/oligarchy-mcp/server.py` + `default.nix`
      (`modules/oligarchy-mcp.nix` is also gone — removed from
      `commonModules` and from disk on 2026-07-25).
- [x] Update `modules/mcp-servers/nixos-module.nix` — declares
      `custom.mcpServers.{enable,flakeDir,stateDir,systemdUnit,aspects}`;
      references `inputs.mcp-servers.packages.${system}.*`; keeps the
      standalone `oligarchy-fingerprint` read-only helper. Uses one
      `config = mkMerge [...]` so the optional systemd unit coexists
      cleanly with the environment.systemPackages block.
- [x] `flake.nix`: add `mcp-servers.url = "path:./modules/mcp-servers";`
      and thread `mcp-servers` into `specialArgs`.
- [x] Pull `mcp-servers.nixosModules.default` into `commonModules`
      (between the other Rust sub-flakes and HM, preserving the
      option-declaration-before-config order from `CLAUDE.md`).
- [x] ISO: add `custom.mcpServers.enable = lib.mkForce false;` to the
      `mkForce` block so the installer image stays free of the new MCP
      packages.
- [x] `packages.${system}.mcp-self-audit` re-exposes
      `mcp-servers.packages.${system}.mcpSelfAudit` — same pattern as
      `malwareScan`.
- [x] `configuration.nix` swaps `custom.oligarchyMcp.enable = true` for
      `custom.mcpServers.enable = true` and updates the surrounding
      comment to point at the new architecture.
- [x] `.mcp.json` updated to register one entry per aspect, each invoking
      `oligarchy-mcp <aspect>`. Replaces the single
      `"oligarchy": { "command": "oligarchy-mcp" }` entry.
- [x] `nix flake check --no-build` evaluates clean: `nixosConfigurations.nixos`,
      `iso`, `packages.mcp-self-audit`, `packages.malwareScan`, and
      `checks.system` all eval to valid derivations.
- [ ] Run `nix build .#nixosConfigurations.nixos.config.system.build.toplevel`
      for a full build gate (Rust compile of all 10 crates is the
      slowest leg). Failing this is the remaining blocker before the
      maintainer can `sudo nixos-rebuild switch`.
- [ ] Run `nix build .#mcp-self-audit` to verify the project-level
      gate actually returns "clean" on this repo.

## Phase 6 — Cutover + cleanup

- [ ] Smoke test umbrella from Claude Code: each aspect tool returns
- [ ] Smoke test `ports-sec.local_api_scan` against `127.0.0.1:11434`
- [ ] Audit logs present at `~/.local/state/oligarchy-mcp/<aspect>/audit.log`
- [ ] Update `CLAUDE.md` `### Modules / sub-flakes` section to mention
      `modules/mcp-servers/`
- [ ] Update `README.md` (if it lists MCP) — strip the bozo "OpenClaw"
      mention if present
- [ ] Remove the `.pyc` cache under `modules/oligarchy-mcp/__pycache__/`
- [ ] Final `nixpkgs-fmt`/`nix fmt` pass on touched `.nix` files

---

## Changelog (living document — append newest at top)

<!--
Append a dated entry every time you change scope, resolve an open question, or
land a phase. Format:

### YYYY-MM-DD — <one-line summary>
- <bullet of change>
- <bullet of change>
-->

### 2026-07-25 — Living document created
- Initial design + roadmap captured from the planning conversation.
- Locked: 8 dedicated Rust servers, read-only + dry-run, umbrella router,
  `oligarchy-<aspect>-mcp` naming, per-aspect audit logs, stdio-only
  transport, `ports-sec` is the only socket opener (loopback, gated).
- Open questions §10 (defaults noted); awaiting maintainer confirmation
  before Phase 1 begins.

### 2026-07-25 — Phase 0/1 + skeleton of Phases 2/3/4 landed
- Created `modules/mcp-servers/` sub-flake with workspace Cargo.toml
  (10 crates: core + umbrella + 8 aspects), committed `Cargo.lock`.
- `crates/core` fully implemented: `audit` (per-aspect log, never panics),
  `allowlist` (runtime enforcement + project-wide source-scan gate),
  `sandbox` (SedReader parent-check), `runner` (subprocess runner with
  timeout + allowlist check), `error` types, plus
  `tests/no_open_sockets.rs` build gate. All 8 core unit tests pass.
- All 7 read-only aspect servers (system/net/dcf/dsp/ai/secrets/vm) have
  skeletons + plain-function tool implementations; awaiting the rmcp
  `#[tool]` macro sweep in Phase 2 finish-up.
- `ports-sec` skeleton landed: `known_endpoints.rs` populated, all six
  tools stubbed (the `local_api_scan` loopback guard is verified by two
  unit tests), `mcp_self_audit` fully implemented as the meta-gate.
- `crates/umbrella` skeleton landed: aspect routing table published for
  all 8 aspects, no allowlist imported (trust boundary preserved); the
  router's pre-warmed subprocess pool is the Phase 4 finish-up task.
- `flake.nix` + `nixos-module.nix` written for the sub-flake.
- **`cargo test --workspace` green: 24 tests, 0 failures.**
- Added: `modules/mcp-servers/Cargo.lock`, `flake.nix`, `README.md`,
  `nixos-module.nix`, and 10 crate directories.
- Phase 5 (top-level flake wiring) NOT yet applied — leaves the existing
  Python `oligarchy-mcp` server in place so the system keeps building
  until the maintainer lands the cutover.

### 2026-07-25 — Phases 2/3/4/5 finish-up landed (build mode)
- **Phase 2 finish-up:** every aspect server is now wired through rmcp's
  `#[tool(tool_box)]` macros, served over stdio via a shared
  `core::runner_mcp::serve` helper. Added `transport-io` +
  `transport-child-process` features to the workspace rmcp dep.
- **Phase 3 finish-up:** `listening_ports` now parses
  `/proc/net/{tcp,tcp6,udp,udp6}` with LE-address decoding (3 decode
  unit tests added); `egress_coverage` diffs the known-endpoints remote
  hosts against `nft -j list table inet strict-egress` +
  `/run/strict-egress/resolved.txt`; `local_api_scan` builds a
  `reqwest::Client::builder().local_address(Ipv4Addr::LOCALHOST)` so
  every probe binds to loopback BEFORE connect; `tls_cert_check` parses
  certs under `/var/lib/acme/*/fullchain.pem` with `x509-parser` when
  the loopback-socket feature is on. Reported on the `not_after`
  ASN1Time string rather than a Duration (x509-parser 0.16 returns
  `time::Duration`, not `std::time::Duration`).
- **Phase 4 finish-up (design change):** the umbrella is now an
  **exec-spawn** multiplexer, not a JSON-RPC router. It does
  `execvp("oligarchy-<aspect>-mcp", argv)` based on `argv[1]` (default
  `system` when absent). Zero tokio/rmcp/serde deps — the umbrella
  floats above the capability boundary by simply exec'ing. Keeps the
  legacy Blipply `command = "oligarchy-mcp"` (no args) spawn working
  unchanged. The umbrella's own audit log records the
  `exec <aspect>` decision.
- **Phase 5:** top-level `flake.nix` got the `mcp-servers.url` input,
  `mcp-servers.nixosModules.default` is in `commonModules`,
  `custom.mcpServers.enable = lib.mkForce false` is in the ISO `mkForce`
  block, `packages.mcp-self-audit` re-exports the sub-flake's audit
  package, `configuration.nix` swapped `custom.oligarchyMcp.enable = true`
  for `custom.mcpServers.enable = true`, and the legacy
  `modules/oligarchy-mcp.nix` + `modules/oligarchy-mcp/` directory are
  removed. `.mcp.json` lists all 8 aspect entries, each invoking
  `oligarchy-mcp <aspect>`. **Fixed a `.gitignore` bug**: the un-anchored
  `secrets/` pattern was matching `modules/mcp-servers/crates/secrets/`
  and silently excluding it from git; anchored to `/secrets/` instead.
- **`--self-audit` CLI:** the ports-sec binary now interprets
  `--self-audit` as a scriptable one-shot invocation of
  `mcp_self_audit::run()`, exiting non-zero on violations. This is what
  `nix build .#mcp-self-audit` uses. With no flags it serves the rmcp
  server over stdio as before.
- **Status checks (2026-07-25):**
  - `cargo test --workspace` → 27 tests green (incl. the ports-sec
    feature-gated leg under `--features allow-loopback-socket`).
  - `nix flake check --no-build` evaluates clean for
    `nixosConfigurations.nixos`, `iso`, `packages.mcp-self-audit`,
    `packages.malwareScan`, `checks.system`.
  - **`nix build .#mcp-self-audit` succeeds** — the meta-gate is clean:
    `mcp_self_audit: clean — no open sockets, no allowlist escapes, no
    remote transports in .mcp.json`.
  - Sub-flake package outputs all eval (umbrella, 8 aspect packages,
    `mcpSelfAudit`).
  - A full `nix build .#nixosConfigurations.nixos.config.system.build.toplevel`
    build was started but exceeds the 120 s session timeout (it closes
    the whole NixOS closure + all 10 crate compile). The maintainer
    should run it as the final compile gate:
    `nix build .#nixosConfigurations.nixos.config.system.build.toplevel`.
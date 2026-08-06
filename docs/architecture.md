# Oligarchy NixOS — Architecture

> Straight technical reference. The README is in-character satire; this file
> is the no-spin companion. The `flake.nix` and `CLAUDE.md` remain the source
> of truth for operational details; this document exists for navigability.

## 1. Overview

A single Nix flake that defines a complete NixOS distribution targeting the
**Framework 16 AMD 7040** (with Intel and NVIDIA Optimus fallbacks). The
build artifact is an operating system, not an application — there is
nothing to "run" beyond `nixos-rebuild switch`.

| | |
|---|---|
| Base | NixOS, nixpkgs `nixos-25.11` stable (`nixpkgs-unstable` available via the `unstable` overlay) |
| State version | `25.11` |
| Primary target | Framework 16 AMD 7040 (Ryzen 7 7840HS, Radeon 780M iGPU) |
| Alternate targets | pure Intel iGPU, Intel + NVIDIA Optimus dGPU |
| Primary desktop | Hyprland (Wayland); Plasma 6, X11 fallbacks |
| Kernel variants | `zen`, `xanmod`, `latest`, `lts` (6.12), `cachyos-bore` (opt-in) |
| DSP | Real-time coprocessor guest via KVM/QEMU + NETJACK, isolated CPU core `isolcpus=0` |
| AI | Local Ollama on ROCm (AMD) / CUDA (Optimus) / CPU fallback; `ai-stack` CLI with presets |
| MCP | 9 dedicated, read-only Rust MCP servers — one per OS aspect — plus the `ports-sec` auditor |

## 2. Flake composition

`flake.nix` defines three NixOS configurations
(`nixosConfigurations.nixos`, `nixos-intel`, `nixos-optimus`) plus the
installer ISO (`packages.x86_64-linux.iso`).

### Input layers (order matters)

`mkHost` assembles the system from three layers, in this order:

1. **Third-party modules** — `determinate` (Nix installer flakehub),
   `sops-nix` (secrets), `nixos-hardware` (`framework-16-7040-amd` profile),
   `fw-fanctrl` (Framework fan control), `demod-ip-blocker` (ingress
   blocklist), `lanzaboote` (secure boot, opt-in).
2. **Home Manager** — `home-manager.nixosModules.home-manager`, with
   `users.asher = import ./home/home.nix`.
3. **Local modules + sub-flakes** — pinned `path:` inputs for `boot-intro`,
   `greeting`, `blipply-assistant`, `vm-manager`, `demod-voice`, `dsp-ctl`,
   `mcp-servers` — plus the `./modules/*.nix` files and `./configuration.nix`.

`specialArgs` threads `inputs`, `nixpkgs-unstable`, `vm-manager`,
`dsp-ctl`, and `mcp-servers` into every module. The commented-out
`archibaldos` input is the template for adding the external DSP
coprocessor when available.

### Output shape

| Output | Purpose |
|---|---|
| `nixosConfigurations.nixos` | Framework 16 AMD (primary) |
| `nixosConfigurations.nixos-intel` | pure Intel iGPU |
| `nixosConfigurations.nixos-optimus` | Intel iGPU + NVIDIA dGPU (PRIME offload) |
| `packages.x86_64-linux.iso` | install ISO (Calamares-Plasma6 + a reduced module set) |
| `packages.x86_64-linux.default` | alias to `iso` |
| `packages.x86_64-linux.malwareScan` | build gate — YARA-scan the system closure |
| `packages.x86_64-linux.mcp-self-audit` | build gate — verify MCP workspace stays socket-free outside `ports-sec` |
| `checks.x86_64-linux.system` | minimal check (eval the toplevel) |
| `devShells.default` | `nil` LSP, `nixpkgs-fmt`, qemu, virt-manager, debug tools |

## 3. `configuration.nix` — the toggle bank

The central system module. Most features are gated behind custom options
that **default to off** in their declaring module; enabling a feature
usually means setting its `custom.*` / `services.*` option to `true` here
rather than editing the module.

Option namespaces in play:

| Namespace | Handles |
|---|---|
| `custom.*` | `custom.steam`, `custom.audio`, `custom.dcfCommunityNode`, `custom.dcfIdentity`, `custom.mcpServers`, `custom.malwareShield`, `custom.secrets`, `custom.secureBoot`, `custom.kernel.variant`, `custom.platform.gpu`, `custom.security.hardening`, `custom.dsp.enable` |
| `services.*` | project-defined services like `services.ollamaAgentic`, `services.dcf-tray`, `services.boot-intro`, `services.oligarchyGreeting`, `services.dsp-vm` |
| `networking.firewall.strictEgress` | the nftables egress firewall (`modules/security/strict-egress.nix`) |
| `hardware.cpuSecurity` | CPU/kernel mitigations (forced spectre/MDS/SRSO + MSR-write block) |

## 4. Installer ISO

Built separately via `nixos-generators` from a *reduced* module set layered
on the upstream Calamares-Plasma6 installer. Every always-on production
service is force-disabled with `lib.mkForce` so the ISO stays lightweight
and installable:

```
ollamaAgentic, dcfCommunityNode, dcfIdentity, dcf-tray,
strictEgress, cpuSecurity, hardening, malwareShield, secrets, mcpServers
```

**Convention:** when adding a new always-on service to
`configuration.nix`, check whether the ISO `mkForce` block in `flake.nix`
also needs a matching disable line.

## 5. `modules/` — subsystems

Each `.nix` file declares the options + config for one subsystem. Several
directories are **self-contained sub-flakes with their own `flake.nix`**
and source trees, not plain modules — when changing one, build/iterate
inside that sub-flake; the top-level flake consumes it as a pinned `path:`
input.

### Plain modules

| Module | Responsibility |
|---|---|
| `modules/kernel.nix` | `custom.kernel.variant` — zen/xanmod/latest/lts/cachyos-bore. LTS is pinned to `linuxPackages_6_12` with EOL warnings evaluated against the nixpkgs input's `lastModified` (pure, dirty-tree-immune) |
| `modules/audio.nix` | PipeWire + WirePlumber + `custom.audio` |
| `modules/dcf-community-node.nix` | DeMoD Compute Fabric community node |
| `modules/dcf-identity.nix` | DCF identity / billing |
| `modules/dcf-tray.nix` | DCF tray controller (KDE/Qt) |
| `modules/agentic-local-ai.nix` | Ollama + ROCm/CUDA/CPU (`services.ollamaAgentic`) |
| `modules/secrets.nix` | sops-nix wiring for `custom.secrets` |
| `modules/secure-boot.nix` | lanzaboote signed boot chain + optional TPM2-sealed LUKS |
| `modules/platform.nix` | GPU/CPU/framework probes, `custom.platform.gpu`, kernel-module fixes (e.g. AMD `usb-storage.quirks=:u`), Framework "You are based" banner |
| `modules/personas.nix` | `studio / gaming / dev / battery` — one-switch re-arming of kernel + DSP + AI + audio quantum + power (`dev` is the default) |
| `modules/blipply-integration.nix` | Voice assistant wiring; reads the MCP over stdio |

### Sub-flakes

| Sub-flake | What it builds | NixOS module it exposes |
|---|---|---|
| `modules/greeting/` | Rust login greeter (Kitty graphics TUI) | `nixosModules.greeting` |
| `modules/boot-intro/` | Rust boot-intro suite (FFmpeg-rendered CRT cinematic, 9 themes) | `boot-intro`/`-tui`/`-api` |
| `modules/blipply-assistant/` | Rust voice assistant (STT/TTS/VAD, UI, ollama integration) | its own `nixosModule` |
| `modules/demod-voice/` | local TTS / voice cloning (Coqui XTTS-v2, Piper) | `nixos-module.nix` |
| `modules/dsp-ctl/` | Rust TUI/CLI for the ArchibaldOS DSP VM | its own `nixosModule` |
| `modules/mcp-servers/` | 11-crate Rust workspace: 9 dedicated read-only aspect MCP servers + umbrella `oligarchy-mcp` + ports-sec auditor | `nixosModules.default` |
| `modules/ArchibaldOS/` | the RT DSP guest OS, its own flake under `modules/ArchibaldOS/modules/` | its own modules |

## 6. `vm-manager/` — VMs

A sub-flake providing two NixOS modules — `quickemu-vm` and `dsp-vm` —
plus per-VM definitions in `vm-manager/config/`:

- **DSP VM** — latency-critical RT guest (NETJACK, isolated CPU core via
  `isolcpus=0`, RT BORE kernel, kexec recovery). The headline feature.
- **Coding sandbox** — development isolation
- **Kali** — penetration-testing guest
- **OpenWRT** — router simulation

## 7. `home/` — Home Manager

User environment for `asher`. `home/home.nix` is the entrypoint; it
builds a feature/profile set (`defaultFeatures`, `profiles/`) that gates
desktop pieces, and a theme/palette system in `home/themes/` (the
`p` / `activeTheme` shorthand seen throughout).

Layout split:

```
home/
├── apps/      — KDE/Qt/GTK theming
├── hyprland/  — Hyprland config
├── waybar/    — Waybar widgets (DCF/Ollama/DSP/caffeine indicators)
├── x11/       — X11 fallbacks
├── terminal/ — Kitty/foot/shell integrations
├── shell/     — zsh/fish aliases, completions, prompts
└── themes/    — the palette system
```

Many `home/apps/*` modules take a `theme`/palette argument rather than
reading global config, so the same module builds differently against
different palettes.

## 8. Security — the iron curtain

Layered defence, with every control a declarative NixOS option that
defaults to off unless noted. See `docs/security-hardening.md` for the
rollout runbook.

| Control | Module / option | Default | Notes |
|---|---|---|---|
| CPU/kernel mitigations | `hardware.cpuSecurity` (preset `hardened`) | **on** | Forced spectre/MDS/SRSO mitigations, MSR-write block, kernel-image protection |
| SSH keys-only + fail2ban | `custom.security.hardening` (preset `hardened`) | **on** | `PasswordAuthentication no`, `AllowUsers`, `MaxAuthTries 3`; brute-force banning with private ranges exempt. Lockout-guard assertion requires a declared key |
| AppArmor + auditd | `custom.security.hardening.{apparmor,auditd}` | off (soak first) | Flip on after a clean soak; complain-first profiles |
| USBGuard | `custom.security.hardening.usbguard` (preset `paranoid`) | off | Blocks newly-plugged USB; disruptive with Framework expansion cards |
| Strict egress firewall | `networking.firewall.strictEgress` | **on, dry-run** | Default-deny outbound allowlist as a standalone nft `output` table (coexists with the ingress firewall + IP blocker). Soak on `WOULDBLOCK` logs, then set `recovery.dryRun = false` |
| Malware Shield | `custom.malwareShield` (level `monitor`) | **on** | ClamAV + lynis/unhide + AIDE + YARA; log-only until you raise to `quarantine`. YARA walks via `find(1)` (no `-L`) to dodge symlink cycles. `custom.malwareShield.yara.excludePaths` skips e.g. Claude Code transcripts. Closure scanned at build via `nix build .#malwareScan` |
| Ingress IP blocklist | `services.demod-ip-blocker` | **on** | Refreshes every 24h |
| Rootless Docker | `virtualisation.docker.rootless` | **on** | Daemon runs as the user; no root-equivalent `docker` group |
| Secure Boot | `custom.secureBoot.enable` | off | lanzaboote signed chain + optional TPM2 LUKS |
| Secrets | `custom.secrets` (sops-nix) | **on** | Age key lives at `/var/lib/sops-nix/key.txt` (never in-store); encrypted `*.enc.env` only |

`oligarchy-security status` (also `oligarchy-ctl status`, the DCF tray,
and the MCP `security_status` tool) reports live posture.

### `strict-egress` mechanics (`modules/security/strict-egress.nix`)

A standalone nft `output` table that **default-denies outbound traffic**
except for an allowlist of:

- **static IPs** — private nets + `cfg.allow.ips`
- **domains** — `cfg.allow.domains` + preset bundles (e.g. `nix`, `gaming`,
  `dev`) + `autoDetectDomains` (resolved from known-daemon configs)
- **ports** — `cfg.allow.ports`
- **uids** — `cfg.allow.uids` (allow specific daemons to egress
  regardless of destination)

`recovery.dryRun = true` (the default) switches the policy to `accept`
and logs `WOULDBLOCK` lines for every would-have-been-denied flow, so you
can soak-shape the allowlist before flipping to enforcement. A curl probe
guards activation to avoid locking the host out.

The table coexists with the upstream NixOS ingress firewall — it adds a
new `output` hook rather than replacing the firewall chain.

## 9. MCP servers — the agent surface

Nine dedicated, **read-only** Model Context Protocol servers — one per
OS aspect — plus a dedicated port/API security-audit server. All are
Rust binaries spawned by Claude Code / Blipply over stdio, with no network
listener and no remote-plugin fetch. The agent surface can never mutate
the running system.

See `docs/mcp-servers-roadmap.md` for the full design + living roadmap;
the short form:

| Aspect | Binary | Surface (read-only) |
|---|---|---|
| system | `oligarchy-system-mcp` | `system_status`, `service_status`, `journal_tail`, `kernel_options`, `gpu_options`, `dry_build`, `flake_check`, `list_modules`, `read_module` |
| net | `oligarchy-net-mcp` | `egress_status`, `egress_test_host`, `dns_resolve`, `nft_list_sets`, `ip_blocker_status` |
| dcf | `oligarchy-dcf-mcp` | `dcf_status` (community-node container), `mesh_peers`, `identity_status` (sops config presence only — no decrypt), `tray_status` |
| hydramesh | `oligarchy-hydramesh-mcp` | `hydramesh_status`, `hydramesh_peers`, `hydramesh_metrics`, `hydramesh_version`, `dcf_node_status`, `dcf_node_peers`, `node_service_status`, `node_config`, `hydramodem_status`, `hydramodem_loopback` |
| dsp | `oligarchy-dsp-mcp` | `dsp_status`, `audio_pipeline_status`, `dsp_vm_status`, `netjack_latency` |
| ai | `oligarchy-ai-mcp` | `ai_status`, `ollama_models`, `ollama_running`, `blipply_status`, `voice_status` |
| vm | `oligarchy-vm-mcp` | `vm_list`, `vm_status`, `vm_disk_usage`, `vm_port_forwards` |
| secrets | `oligarchy-secrets-mcp` | `secrets_inventory` (redacted metadata), `sops_status`, `age_keys_present` — **no decrypt path by construction** |
| ports-sec | `oligarchy-ports-sec-mcp` | `listening_ports`, `egress_coverage`, `local_api_scan`, `nmap_self_scan`, `mcp_self_audit`, `tls_cert_check` |

Each aspect server reaches a CLI only through `runner::run(ASPECT, prog, …)`,
which refuses and audit-logs any `prog` outside that aspect's list in
`modules/mcp-servers/crates/core/src/allowlist.rs`. That check is at
**runtime**. The build-time gates (`crates/core/tests/no_open_sockets.rs` and
`nix build .#mcp-self-audit`) source-scan every crate for socket and
HTTP-client patterns; they do *not* verify `Command::new` literals against the
lists, so a crate bypassing `runner::run` would slip past them.

### `ports-sec` — the dedicated auditor

Six read-only tools that together answer "are all API and ports
secured?":

1. `listening_ports` — parses `/proc/net/{tcp,tcp6,udp,udp6}` directly
   (no `ss` spawn) and flags binds on `0.0.0.0` / `::` as
   `exposed_to_lan`. PID/unit resolution is a future polish.
2. `egress_coverage` — diffs the well-known endpoints table
   (`crates/ports-sec/src/known_endpoints.rs`) against the live
   `nft list table inet strict-egress` ruleset + the resolver log;
   proposes exact `nft add element …` lines for gaps but never applies
   them.
3. `local_api_scan` — opens a `reqwest::Client` **bound to `127.0.0.1`
   only** and probes each known local API for status + auth. The ONE
   crate allowed to open sockets, gated behind a feature flag
   `allow-loopback-socket`; the rest of the workspace is source-scanned
   to confirm it doesn't.
4. `nmap_self_scan` — runs `nmap -sT -p- 127.0.0.1` and `::1`
   (loopback-only, hard-coded); optional LAN scan validates the iface
   via `ip -o link` before doing anything.
5. `mcp_self_audit` — meta-security for the MCP project itself: walks
   every crate's `src/**/*.rs` for forbidden patterns
   (`TcpListener::bind`, `reqwest` outside `ports-sec`, etc.) and
   verifies `.mcp.json` has no URL/HTTP transport entries. Doubles as
   the `nix build .#mcp-self-audit` build gate.
6. `tls_cert_check` — parses certbot PEM-on-disk certs under
   `/var/lib/acme/*/fullchain.pem` with `x509-parser` and reports
   subject / issuer / `not_after`.

### Umbrella router

`oligarchy-mcp` is a thin exec-spawn multiplexer. `.mcp.json` invokes it
with one aspect argument and the umbrella `execvp`'s into the matching
`oligarchy-<aspect>-mcp` binary. It imports **no** allowlist — a
compromised umbrella cannot grant new capabilities. The legacy Blipply
`command = "oligarchy-mcp"` (no args) execs into `system` by default,
keeping the old spawn working unchanged.

## 10. DSP coprocessor — the headline feature

A real-time audio DSP guest running on the same hardware as the chaotic
Linux host, isolated so that the host can thrash (Doom at 300+ FPS) while
the guest keeps audio latency in the sub-millisecond range.

| | |
|---|---|
| Host kernel | CachyOS/Zen/XanMod/latest/lts/BORE (per `custom.kernel.variant`) |
| RT guest | ArchibaldOS (custom RT NixOS, BORE scheduler) via KVM/QEMU |
| Isolation | `isolcpus=0` — CPU 0 surrendered to the DSP guest |
| Audio bridge | NETJACK over shared memory |
| Latency | 0.38–0.66 ms @ 96 kHz / 32–64 samples (theoretical), ~1.33 ms measured |
| Recovery | 180–350 ms kexec restart |
| Persona | `studio` arms the DSP and drops AI; `dev` is the day-to-day default |

Personas (`studio / gaming / dev / battery`) re-arm the whole rig in one
switch — kernel, DSP coprocessor, AI tier, audio quantum, gamemode and
power policy. Runtime toggles (power profile, animations, live PipeWire
quantum) flip instantly; build-time pieces are written to
`oligarchy-local.nix` and applied on the next `nixos-rebuild`.

**DSP Rigs — Pedalboard as Code** (optional via `custom.dsp.enable`):
declarative LV2 plugin chains *and* Faust `.dsp` programs that run as JACK
clients and hot-swap like personas. Your tone is a line in your NixOS
config.

## 11. Local AI

`services.ollamaAgentic` + the `ai-stack` CLI manage a local Ollama
deployment on whichever silicon the host has — ROCm (AMD), CUDA
(Optimus), or CPU fallback.

| Preset | VRAM | Parallelism | Use case |
|---|---|---|---|
| `cpu-fallback` | — | 1 | no GPU |
| `default` | 8 GB | 4 | basic GPU |
| `high-vram` | 16 GB | 8 | RTX 3090/4090 |
| `rocm-multi` | 24 GB | 12 | AMD multi-GPU |
| `pewdiepie` | 24 GB+ | 16 | absolute maximum |

DeMoD Voice (Coqui XTTS-v2 + Piper) provides local TTS / voice cloning.

## 12. DCF — DeMoD Compute Fabric

Real-time agent-to-agent fabric split across three modules:

- `dcf-community-node` — the mesh node
- `dcf-identity` — identity / billing with sops-protected keys
- `dcf-tray` — KDE/Qt tray controller for the user session

All run in hardened rootless Docker containers with least-privilege
secrets management. The tray auto-starts on login.

## 13. Conventions

- **Unfree + broken allowed.** `pkgsConfig` sets `allowUnfree = true` and
  `allowBroken = true`; builds may pull proprietary firmware/drivers
  (NVIDIA, etc.).
- **Pin everything through the flake.** New external dependencies become
  flake inputs, not ad-hoc fetches — the project explicitly avoids
  unpinned sources.
- ** Secrets** use `sops-nix`. `secrets/` is git-ignored except
  `secrets/.sops.yaml`. Never commit decrypted material, `*.age`, or
  `secrets/secrets.yaml`.
- **State version is `25.11`** on `nixos-25.11` (nixpkgs stable). Keep new
  modules consistent with that. `nixpkgs-unstable` is available via the
  `unstable` overlay for cherry-picks.
- **MCP servers are read-only + dry-run by construction.** The agent
  surface can never mutate the running system. Each aspect server has a
  compile-time-checked CLI allowlist; the `ports-sec` crate is the only
  one permitted to open sockets (loopback-only, feature-gated). `nix
  build .#mcp-self-audit` enforces this at the project level.

## 14. Related documents

| Doc | What it covers |
|---|---|
| `CLAUDE.md` | operational guidance for Claude Code working on this repo |
| `docs/architecture.md` | this file — the straight technical reference |
| `docs/mcp-servers-roadmap.md` | the MCP server design + living roadmap |
| `docs/security-hardening.md` | security rollout runbook (presets, soak steps) |
| `docs/secure-boot-enrollment.md` | secure-boot enrollment procedure |
| `docs/dcf-mesh-agent.md` | DCF mesh agent design |
| `README.md` | the in-character satire (technical tables near the bottom are the source of truth) |

## 15. Build & verification

```bash
# full evaluation + build (the actual build gate)
nix build .#nixosConfigurations.nixos.config.system.build.toplevel

# install ISO build
nix build .#iso

# closure YARA scan (matches any of modules/security/yara-rules/*.yar in every path of the closure)
nix build .#malwareScan

# MCP source audit (fails if any crate opens a socket outside ports-sec, or escapes its allowlist)
nix build .#mcp-self-audit

# eval-only check (full toplevel is already in checks; slow gates left out)
nix flake check

# MCP workspace unit tests (per-crate allowlist + build-gate tests)
cd modules/mcp-servers && cargo test --workspace
```

## 16. Hardware-specific notes

- `nixos-hardware`'s `framework-16-7040-amd` profile handles most AMD
  tuning; `fw-fanctrl` adds Framework-specific fan control.
- The `usb-storage.quirks=:u` kernel param stops a USB audio patchbay
  thrash on `1022:15b9`.
- The platform module prints a green "You are based." banner to
  `/dev/console` at `sysinit.target` before the display manager — only on
  genuine Framework 16 hardware.
- For Optimus hosts: fill in PCI bus IDs and the Intel/NVIDIA driver
  config in `hosts/nixos-optimus/hardware-configuration.nix`; the dGPU
  stays asleep until `nvidia-offload <cmd>` summons it.
- Idle power is 5–7 W via `power-profiles-daemon`, `amdgpu` tuning,
  `fw-fanctrl`, and clamshell scripts.

## 17. Branding / palette

The desktop is themed as "DeMoD war room":

| Token | Value | Meaning |
|---|---|---|
| primary | `#00D4AA` | DCF online |
| alert | `#FF6B6B` | DCF offline |
| warning | `#FFE66D` | caution |
| background | `#1A1A2E` | dark |
| surface | `#16213E` | panel |
| text | `#EAEAEA` | body |

Six palettes cycle via `Super+F7` (`demod / vim / amber / purple / rose /
gold`); the `Super+F8` theme switcher rebuilds the colour stack. All
`home/apps/*` modules take a `theme`/palette argument so the same module
builds differently against different palettes.
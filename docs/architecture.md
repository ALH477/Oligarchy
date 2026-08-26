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
| Primary target | Framework 16 AMD 7040 (Ryzen 7 7840HS, Radeon 780M iGPU + optional Navi 33/RX 7700S dGPU expansion module) |
| Alternate targets | Framework 13 AMD 7040 (iGPU only, unverified on real hardware), pure Intel iGPU, Intel + NVIDIA Optimus dGPU |
| Primary desktop | Hyprland (Wayland); Plasma 6, X11 fallbacks |
| Kernel variants | `zen`, `xanmod`, `latest`, `lts` (6.12), `cachyos-bore` (opt-in) |
| DSP | Real-time coprocessor guest via KVM/QEMU + NETJACK, isolated CPU core `isolcpus=0` |
| AI | Local Ollama on ROCm (AMD) / CUDA (Optimus) / CPU fallback; `ai-stack` CLI with presets |
| MCP | 9 dedicated, read-only Rust MCP servers — one per OS aspect — plus the `ports-sec` auditor |

## 2. Flake composition

`flake.nix` defines four NixOS configurations
(`nixosConfigurations.nixos`, `nixos-fw13`, `nixos-intel`,
`nixos-optimus`) plus the installer ISO (`packages.x86_64-linux.iso`).

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
   `mcp-servers`, `oligarchy-forge`, `oligarchy-plugins`, `demod-talk`,
   `minecraft` — plus the `./modules/*.nix` files and `./configuration.nix`.

`specialArgs` threads `inputs`, `nixpkgs-unstable`, `vm-manager`,
`dsp-ctl`, `oligarchy-forge`, `mcp-servers`, `hydramesh` and `demod-talk`
into every module. The commented-out
`archibaldos` input is the template for adding the external DSP
coprocessor when available.

### Output shape

| Output | Purpose |
|---|---|
| `nixosConfigurations.nixos` | Framework 16 AMD (primary) |
| `nixosConfigurations.nixos-fw13` | Framework 13 AMD (iGPU only) |
| `nixosConfigurations.nixos-intel` | pure Intel iGPU |
| `nixosConfigurations.nixos-optimus` | Intel iGPU + NVIDIA dGPU (PRIME offload) |
| `packages.x86_64-linux.iso` | install ISO (Calamares-Plasma6 + a reduced module set) |
| `packages.x86_64-linux.default` | alias to `iso` |
| `packages.x86_64-linux.malwareScan` | build gate — YARA-scan the system closure |
| `packages.x86_64-linux.mcp-self-audit` | build gate — verify MCP workspace stays socket-free outside `ports-sec` |
| `packages.x86_64-linux.plugins-*` | five build gates for the plugin runtime — see §5b |
| `packages.x86_64-linux.oligarchy-hw-detect` | installer-only helper: picks the matching `nixosConfigurations.*` from DMI |
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
| `custom.*` | `custom.steam`, `custom.audio`, `custom.dcfCommunityNode`, `custom.dcfIdentity`, `custom.mcpServers`, `custom.malwareShield`, `custom.secrets`, `custom.secureBoot`, `custom.kernel.variant`, `custom.platform.gpu`, `custom.platform.displayGpu`, `custom.security.hardening`, `custom.dsp.enable` |
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

## 4b. Installer helper + firmware updates

`nix run .#oligarchy-hw-detect` (also on the ISO's `$PATH` as
`oligarchy-hw-detect`) identifies Framework 13 vs 16 (or neither) via DMI,
prints the matching `nixosConfigurations.*` target, and walks
`nixos-generate-config` for the real disk UUIDs the per-host
`hardware-configuration.nix` stubs need. It also offers to check/apply
pending Framework BIOS/EC firmware via `fwupdmgr` (LVFS) before install —
`services.fwupd.enable = true` is already on in `configuration.nix`
(`UpdateOnBoot=false`; updates are manual, via the `fwupd-refresh` timer or
`fwupdmgr update`), forced on in the ISO too.

For the separate, much riskier question of changing the iGPU's UMA/framebuffer
RAM carve-out (a BIOS Setup NVRAM field, not anything Nix or the kernel
controls) see `docs/bios-uma-unlock.md` and the isolated
`devShells.bios-tools` — deliberately not part of any `nixosConfiguration` or
the ISO.

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
| `modules/platform.nix` | GPU/CPU/framework probes, `custom.platform.gpu`, kernel-module fixes (e.g. AMD `usb-storage.quirks=:u`), Framework "You are based" banner. On dual-AMD-GPU hosts, `custom.platform.displayGpu` (default `"dgpu"`) plus `dgpuPciId`/`igpuPciId` select which GPU client apps (games, anything launched from Hyprland) render on via Mesa `DRI_PRIME`. This never touches Hyprland/Aquamarine's own backend device — the compositor always uses the iGPU, since the dGPU module has no display engine path of its own and telling Aquamarine to open it as primary is a fatal, unrecoverable crash (see `docs/dgpu-steam-forcing.md`) |
| `modules/personas.nix` | `studio / gaming / dev / battery / minimal` — one-switch re-arming of kernel + DSP + AI + audio quantum + power (`minimal` is the fresh-clone default) |
| `modules/blipply-integration.nix` | Voice assistant wiring; reads the MCP over stdio |

### Sub-flakes

| Sub-flake | What it builds | NixOS module it exposes |
|---|---|---|
| `modules/greeting/` | Rust login-*shell* MOTD (Kitty graphics TUI), run via `programs.bash.loginShellInit` — not the greetd/login-prompt greeter (that's `tuigreet`, wired directly in `configuration.nix`). Disabled by default: `services.oligarchyGreeting.enable` is never set to `true`. | `nixosModules.greeting` |
| `modules/boot-intro/` | Rust boot-intro suite (FFmpeg-rendered CRT cinematic, 9 themes) | `boot-intro`/`default` (no `-tui`/`-api` variants exist) |
| `modules/blipply-assistant/` | Rust voice assistant (STT/TTS/VAD, UI, ollama integration) | its own `nixosModule` |
| `modules/demod-voice/` | local TTS / voice cloning (Coqui XTTS-v2, Piper) | `nixos-module.nix` |
| `modules/dsp-ctl/` | Rust TUI/CLI for the ArchibaldOS DSP VM | its own `nixosModule` |
| `modules/mcp-servers/` | 11-crate Rust workspace: 9 dedicated read-only aspect MCP servers + umbrella `oligarchy-mcp` + ports-sec auditor | `nixosModules.default` |
| `modules/oligarchy-forge/` | sandboxed coding-agent runner — a TOML schema compiles to a generated flake building a `dockerTools.streamLayeredImage`, run via rootless Podman; Ratatui dashboard. **Read-write**, so deliberately outside the MCP surface | its own `nixosModule` (`custom.oligarchyForge`) |
| `modules/oligarchy-plugins/` | tiered sandboxed plugin runtime — one WIT ABI across three sandbox tiers, with per-instance W^X. The FX Bazaar's foundation. **Read-write**, so also outside the MCP surface. See §5b | `nixosModules.plugins` / `.default` |
| `modules/demod-talk/` | pure-Lua DCF chat stack (certified text + voice L3, SuperPack/Reed-Solomon transport, StreamDB history). Plaintext by design, so `interface` is mandatory and asserted to be WireGuard | `services.demod-talk` |
| `modules/ArchibaldOS/` | the RT DSP guest OS, its own flake under `modules/ArchibaldOS/modules/` | its own modules |

### 5a. Boot → login ordering

```
sysinit.target
  └─ framework-based-banner.service      (Framework hardware only; before= the next two)
multi-user.target
  └─ boot-intro-player.service           (mpv --vo=gpu on /dev/tty1, before= display-manager.service)
graphical.target
  └─ display-manager.service (= greetd)  (after/wants= boot-intro-player.service, restartIfChanged = false)
       └─ tuigreet → Hyprland session
```

`mpv --vo=gpu` holds DRM master while playing the boot-intro video; on exit
the primary plane can still show the last frame. The blank/unblank repaint
(`clear`/`printf`/`setterm --blank force|poke`) that fixes this lives in
`boot-intro-player`'s `EXIT` trap so it still runs if the unit is killed via
`TimeoutStartSec` or an external stop, not just on the natural-exit path.
`services.greetd.useTextGreeter = true` (since `tuigreet` is a TUI greeter)
makes nixpkgs's own `greetd.nix` module apply `TTYPath`/`TTYReset`/
`TTYVHangup`/`TTYVTDisallocate` to greetd's unit, so the VT greetd claims is
independently guaranteed clean regardless of what boot-intro left behind.
`restartIfChanged = false` on `greetd.service` is a separate, older fix:
without it, `nixos-rebuild switch` restarts greetd on nearly every rebuild
(its `ExecStart` embeds the store path + `$PATH`, which change every
generation), which kills the live Hyprland session it spawned.

### 5b. Plugin runtime (`modules/oligarchy-plugins/`)

`custom.plugins.*`. One WIT ABI (`oligarchy:plugin@0.1.0`) across three
sandbox tiers, selected per plugin from its `plugin.toml` manifest. The
point is **per-instance W^X**: `MemoryDenyWriteExecute` is decided per
plugin from a `jit = none|host|self` manifest field and written into a
systemd drop-in, rather than being set once for the whole machine. A plugin
that genuinely needs a JIT can have one without every other plugin
inheriting the concession.

| Tier | Isolation | `jit = "self"` gets W+X | Install path |
|---|---|---|---|
| `wasm` | wasmtime + WASI, in-process | no — the guest is a wasm sandbox | imperative or declared |
| `native` / `lua` | bwrap + Landlock + seccomp | no — the seccomp filter denies it | imperative or declared |
| `microvm` | a separate kernel (microvm.nix) | **yes**, inside the guest only | **declared only** |

Two structural rules hold the design up:

- **Nobody is in `nix.settings.trusted-users`.** Per the Nix manual that is
  root-equivalent. The trust anchor is instead a signed cache plus its
  pinned key, with every path verified before registration:
  `verify_signature` requires *both* a signature naming a key from
  `trustedPublicKeys` *and* `nix store verify` accepting it — because
  `nix store verify --sigs-needed 1` alone short-circuits for
  content-addressed paths, and `nix store add-path` needs no privilege.
  `custom.plugins.installers` is the option that exists so `trusted-users`
  does not have to be; it grants membership of the group owning the control
  socket, which is the only registry-mutating path.
- **The W^X rule lives in two mirrored places on purpose** —
  `Manifest::wx_enforced()` in `host/src/manifest.rs` and `wxEnforced` in
  `modules/plugins.nix`. Change one and you must change the other;
  `nix build .#plugins-wx-enforcement` boots a real kernel and asserts they
  agree.

Five build gates cover it, all needing KVM and therefore all deliberately
outside `nix flake check`:

| Gate | Proves |
|---|---|
| `plugins-wx-enforcement` | the tier/jit W^X split reaches the systemd unit |
| `plugins-policy-refusal` | policy refuses at *install* time, not at load time |
| `plugins-signed-install` | an unprivileged user can install a signed plugin and only a signed one |
| `plugins-tier1-runtime` | a real `.so` observes the W^X its manifest declared — probing six routes to executable memory, not one |
| `plugins-tier2-runtime` | a self-JIT plugin gets W+X inside a real microVM **and only inside it** (needs *nested* KVM) |

`docs/plugins-roadmap.md` is the integration record, including the known
gaps per stage and a falsification write-up (§4.1) of three W^X bypasses
that made an earlier version of the tier-1 claim false.

Like `oligarchy-forge` and `dsp-ctl` this is a **read-write** tool, so it
stays out of the MCP surface.

## 6. `vm-manager/` — VMs

A sub-flake providing two NixOS modules — `quickemu-vm` and `dsp-vm` —
plus per-VM definitions in `vm-manager/config/`:

- **DSP VM** — latency-critical RT guest (NETJACK, isolated CPU core via
  `isolcpus=0`, RT BORE kernel, kexec recovery). The headline feature.
- **Coding sandbox** — development isolation
- **Kali** — penetration-testing guest
- **OpenWRT** — router simulation

Tier 2 of the plugin runtime (§5b) brings microvm.nix's host module onto
the same machine. There is no option collision — microvm.nix writes
`users.users.microvm`, `systemd.targets.microvms`, `/var/lib/microvms` and
`boot.kernelModules += [ "tap" "vhost_net" ]` (plus `vhost_vsock`, which
the plugin module adds), while vm-manager writes `custom.vm.*` and its own
services — but both want `/dev/kvm`, and that interaction is unexercised.
`microvm.autostart` is deliberately left empty: a plugin's guest is started
by its own unit's `Requires=`, so autostarting would give one guest two
owners.

## 7. `home/` — Home Manager

User environment for `asher`. `home/home.nix` is the entrypoint; it
builds a feature/profile set (`defaultFeatures`, `profiles/`) that gates
desktop pieces, and a theme/palette system in `home/themes/` (the
`p` / `activeTheme` shorthand seen throughout).

8 palettes live in `home/themes/default.nix` as the single source of
truth; `home/apps/theme-variants.nix` renders every palette (not just the
active one) to `~/.config/oligarchy/themes/<id>/` — a JSON palette dump
plus each themed app's own pre-rendered config variant (waybar CSS, wofi
CSS, hyprlock conf, GTK3/4 CSS, a Kvantum theme directory per palette,
a kitty colors-only conf). `theme-switch.sh` reads only these Nix-rendered
files (`toggle`/`set <id>`/`gui`/`cli`/`current`/`list`) and actually
re-skins every consumer live — no rebuild needed — by re-pointing each
app's Home-Manager-managed symlink at the selected variant, rewriting
Kvantum's active-theme pointer, and pushing new colors into running kitty
windows via `kitty @ set-colors` (kitty.nix sets `allow_remote_control` +
a `{kitty_pid}`-suffixed `listen_on`, since the three pre-spawned
scratchpad kitty processes would otherwise collide on one static socket
path). The next `home-manager switch` still resets everything to whatever
`activeThemeName` declares — this is a live preview/override, not a second
source of truth.

Layout split:

```
home/
├── apps/      — KDE/Qt/GTK theming
├── hyprland/  — Hyprland config
├── waybar/    — Waybar widgets (DCF/Ollama/DSP/caffeine/repo-update indicators)
├── x11/       — X11 fallbacks
├── terminal/ — Kitty/foot/shell integrations
├── shell/     — zsh/fish aliases, completions, prompts
└── themes/    — the palette system
```

Many `home/apps/*` modules take a `theme`/palette argument rather than
reading global config, so the same module builds differently against
different palettes.

### 7a. Control center (`home/apps/control-center/`)

Plain bash, deployed to `~/.local/bin`, sharing one action registry so the
two front-ends and the phone-bridge passthrough (`modules/hypr-controller/`)
never duplicate dispatch logic:

- `oligarchy-ctl` — the registry itself: `status` / `cats` / `items <cat>`
  / `all-items` (every category's actions flattened into one list, for
  fuzzy search) / `run <action-id>`. ~50 actions across 10 categories
  (appearance, ai, dsp, dcf, network, security, power, persona, rig,
  system). Mutates live state (`hyprctl keyword`, `pw-metadata`,
  `powerprofilesctl`) and persists build-time choices (persona/kernel/gpu)
  to `~/.config/oligarchy/state.nix` (outside the repo, requires `nixos-rebuild switch --impure` to be picked up) — this is the read-write control layer,
  deliberately separate from the read-only MCP surface.
- `oligarchy-menu` (wofi, Super+D) / `oligarchy-control` (fzf, terminal) —
  both support the category→action browse and a flat "🔎 Search all
  actions…" entry point.
- `persona-menu` (`oligarchy-ctl run persona-menu`) — one-shot picker
  showing all 4 personas with the active one checked, switching via the
  same `apply_persona` logic the flat items use.
- `dcf-control` — small fzf panel over the `dcf` category's read-only
  status (`hydramesh-status`/`-logs`) and mutating actions
  (`hydramesh-restart`/`-pull`); bound directly to `$mod SHIFT, D` when
  `features.enableDCF`.
- `ai` category's `forge-agent` entry launches `oligarchy-forge run --
  $OLIGARCHY_FORGE_AGENT` (default `claude`, a `home.sessionVariables`
  override) when `oligarchy-forge` is installed — see §10 for the agent
  catalog that command can select from.
- `system` category's `repo-check` / `repo-pull` wrap
  `home/scripts/repo-update-check.sh` and a fast-forward-only `git pull`.
  That same script backs waybar's `custom/repo-updates` badge
  (`features.enableDev`-gated): a systemd user timer fetches every 30
  minutes and notifies once per new remote SHA (never repeats for a commit
  already surfaced); the badge itself only polls cached refs (no network
  call) and renders nothing at all when clean — confirmed by screenshotting
  a live instance with deliberately obnoxious CSS on the module, not just
  assumed from an empty string. Resolves whichever branch is actually
  checked out and its real upstream (`@{u}`, falling back to
  `origin/main`/`origin/master`) rather than assuming a branch named
  `main` — the real deployed checkout at `/etc/nixos` is on `master` with
  no upstream configured at all, which a hardcoded comparison would have
  silently done nothing for.

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
| Strict egress firewall | `networking.firewall.strictEgress` | **on, enforcing** | Default-deny outbound allowlist as a standalone nft `output` table (coexists with the ingress firewall + IP blocker). Flipped from dry-run to `recovery.dryRun = false` on the soaked `nixos` host allowlist (`preset = "developer"` + ollama/blipply-assistant/dcf-node-binary domains); `recovery.failOpen = true` still flushes the chain if `cache.nixos.org` becomes unreachable, so a bad allowlist can't brick a rebuild |
| Malware Shield | `custom.malwareShield` (level `monitor`) | **on** | ClamAV + lynis/unhide + AIDE + YARA; log-only until you raise to `quarantine`. YARA walks via `find(1)` (no `-L`) to dodge symlink cycles. `custom.malwareShield.yara.excludePaths` skips known structural false positives: Claude Code transcripts, and this repo's own `modules/security/yara-rules/eicar.yar` + `docs/security-hardening.md` (both legitimately contain the EICAR test string — the rule *is* the EICAR test, and self-matches whenever a checkout of this repo lives under a scanned path). Closure scanned at build via `nix build .#malwareScan` |
| Ingress IP blocklist | `services.demod-ip-blocker` | **on** | Refreshes every 24h |
| Rootless Docker | `virtualisation.docker.rootless` | **on** | Daemon runs as the user; no root-equivalent `docker` group |
| Secure Boot | `custom.secureBoot.enable` | off | lanzaboote signed chain + optional TPM2 LUKS |
| Secrets | `custom.secrets` (sops-nix) | **on** | Age key lives at `/var/lib/sops-nix/key.txt` (never in-store); encrypted `*.enc.env` only |
| Plugin runtime W^X | `custom.plugins` (`allowedTiers`, `allowSelfJit`, `requireSignature`) | off | Per-*instance* `MemoryDenyWriteExecute` from the plugin's own manifest, plus a seccomp filter that also denies anonymous `PROT_EXEC`, `ptrace` and `userfaultfd`, and `NoExecPaths=/ <stateDir>` against plain-file dual mapping. Signed-only install with nobody in `trusted-users`. See §5b |
| Steam/game sandbox | `steam-noswap.slice` + `systemd-run` launch wrapper (icewm menu + `home/apps/desktop-entries.nix`) | **on** | `MemorySwapMax=0` (isolates games from swap/zram — a memory ceiling OOM-kills the game instead of thrashing) plus `NoNewPrivileges`, `ProtectHome`/`Hostname`/`Clock`/`Kernel{Tunables,Logs,Modules}`/`ControlGroups`, `RestrictSUIDSGID`, `LockPersonality`. Deliberately excludes `RestrictNamespaces`/`SystemCallFilter` (breaks Proton's pressure-vessel sandbox), `MemoryDenyWriteExecute` (breaks Wine/Mono JIT), `RestrictRealtime` (GameMode may want RT scheduling) |

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

`recovery.dryRun = true` switches the policy to `accept` and logs
`WOULDBLOCK` lines for every would-have-been-denied flow, letting you
soak-shape the allowlist before flipping to enforcement. The `nixos` host
has completed that soak and now runs with `recovery.dryRun = false`
(enforcing). A curl probe (`recovery.failOpen`) guards activation to avoid
locking the host out if the allowlist turns out to be wrong.

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

Personas (`studio / gaming / dev / battery / minimal`) re-arm the whole rig in one
switch — kernel, DSP coprocessor, AI tier, audio quantum, gamemode and
power policy. Runtime toggles (power profile, animations, live PipeWire
quantum) flip instantly; build-time pieces are written to
`~/.config/oligarchy/state.nix` and applied on the next `nixos-rebuild switch --impure`.

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
| `docs/plugins-roadmap.md` | the plugin runtime design + integration record (§5b) |
| `docs/oligarchy-forge-roadmap.md` | the sandboxed coding-agent runner's design + roadmap |
| `docs/dgpu-steam-forcing.md` | why the compositor never renders on the dGPU |
| `docs/bios-uma-unlock.md` | the iGPU UMA carve-out procedure (out-of-band, not Nix) |
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

# plugin runtime gates — all need KVM, tier2 needs *nested* KVM
nix build .#plugins-wx-enforcement
nix build .#plugins-policy-refusal
nix build .#plugins-signed-install
nix build .#plugins-tier1-runtime
nix build .#plugins-tier2-runtime

# eval-only check (full toplevel is already in checks; slow gates left out)
nix flake check

# MCP workspace unit tests (per-crate allowlist + build-gate tests)
cd modules/mcp-servers && cargo test --workspace
```

## 16. Hardware-specific notes

- `nixos-hardware`'s `framework-16-7040-amd` / `framework-13-7040-amd`
  profiles handle most AMD tuning; `fw-fanctrl` adds Framework-specific fan
  control, shared by both chassis (`custom.platform.framework = true`).
- `custom.platform.frameworkModel` ("13"/"16") only drives banner/display
  text; `custom.platform.hasDgpu` (default `true` when `gpu = "amd"`, `false`
  on the `nixos-fw13` host) gates the dGPU DRI_PRIME routing (Steam,
  Hyprland client apps) so an iGPU-only Framework 13 never gets pointed at a
  PCI device it doesn't have.
- The `usb-storage.quirks=:u` kernel param stops a USB audio patchbay
  thrash on `1022:15b9`.
- The platform module prints a green "You are based." banner to
  `/dev/console` at `sysinit.target` before the display manager — on any
  genuine Framework board (13 or 16).
- For Optimus hosts: fill in PCI bus IDs and the Intel/NVIDIA driver
  config in `hosts/optimus/hardware-configuration.nix`; the dGPU
  stays asleep until `nvidia-offload <cmd>` summons it. `hosts/framework13/`
  and `hosts/intel/` follow the same FILL-IN-UUID stub pattern.
- Idle power is 5–7 W via `power-profiles-daemon`, `amdgpu` tuning,
  `fw-fanctrl`, and clamshell scripts.
- The primary account is `custom.user.name` (default `"asher"`,
  `modules/user.nix`), not a literal scattered across the tree — forking
  this repo for another machine/user means changing that option (and
  `custom.user.sshAuthorizedKeys`), not grepping for a username.

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
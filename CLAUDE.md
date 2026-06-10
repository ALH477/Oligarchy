# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single Nix flake that defines a complete NixOS distribution ("Oligarchy") targeting the **Framework 16 AMD 7040**. It is configuration-as-code: there is one main system (`nixosConfigurations.nixos`), an installer ISO, several locally-vendored sub-flakes (some containing Rust programs), and a Home Manager user config. There is no traditional application to "run" — the build artifact is an OS.

The README is written in heavy in-character satire ("Oligarchy", "war machine", fake legal decrees). Ignore the tone; the technical tables near the bottom and the `flake.nix` are the source of truth.

## Common commands

All commands run from the repo root.

```bash
# Enter the dev shell (Nix LSP `nil`, nixpkgs-fmt, qemu, virt-manager, network/debug tools)
nix develop

# Format Nix files
nixpkgs-fmt <file.nix>

# Evaluate/build the full system without switching (catches most errors)
nix build .#nixosConfigurations.nixos.config.system.build.toplevel

# Apply the config to a running NixOS host
sudo nixos-rebuild switch --flake .#nixos

# Build the installer ISO (the flake's default package)
nix build .#iso          # -> result/iso/nixos-*.iso

# Validate the flake (eval all outputs)
nix flake check

# Update pinned inputs
nix flake update
```

### Tests

NixOS VM integration tests live in `tests/default.nix` using `pkgs.testers.runNixOSTest` (e.g. the `strict-egress` firewall test). **Note:** these are not currently wired into the flake's `outputs` (no `checks`/`packages.test` attribute exists despite the dev-shell banner mentioning `nix run .#test`). To run one, either add it to flake outputs or evaluate it directly, e.g.:

```bash
nix-build tests/default.nix -A strict-egress   # or wire into flake checks first
```

## Architecture

### Flake composition (`flake.nix`)

`nixosConfigurations.nixos` is assembled from three layers, in this order (order matters — option *declarations* must precede modules that *set* them):

1. **Third-party modules** — `determinate`, `sops-nix`, `nixos-hardware` (the `framework-16-7040-amd` profile), `fw-fanctrl`, `demod-ip-blocker`.
2. **Home Manager** — `home-manager.nixosModules.home-manager`, with `users.asher = import ./home/home.nix`.
3. **Local modules + sub-flakes** — the `boot-intro`, `greeting`, `blipply-assistant`, `vm-manager`, and `demod-voice` sub-flakes (referenced as `path:./...` flake inputs), plus the `./modules/*.nix` files and `./configuration.nix`.

`specialArgs` threads `inputs`, `nixpkgs-unstable`, and `vm-manager` into every module. The commented-out `archibaldos` input is the pattern for adding the external DSP coprocessor when available.

The **ISO** (`packages.x86_64-linux.iso`) is built separately via `nixos-generators` from a *reduced* module set layered on the upstream Calamares-Plasma6 installer. It force-disables the heavyweight production services (`ollamaAgentic`, `dcfCommunityNode`, `dcfIdentity`, `dcf-tray`, `strictEgress`) with `lib.mkForce`. When adding a new always-on service, check whether it also needs disabling here.

### `configuration.nix`

The central system module and the main place toggles are flipped. Most features are gated behind custom options and **default to off** in this file — enabling a feature usually means setting its `custom.*`/`services.*` option to `true` here, not editing the module. Option namespaces in play:

- `custom.*` — e.g. `custom.steam`, `custom.audio`, `custom.dcfCommunityNode`, `custom.dcfIdentity`.
- `services.*` — project-defined services like `services.ollamaAgentic`, `services.dcf-tray`, `services.boot-intro`, `services.openclaw-agent`, `services.oligarchyGreeting`.
- `networking.firewall.strictEgress` — the nftables egress firewall (`modules/security/strict-egress.nix`).

### `modules/`

Each `.nix` file declares the options + config for one subsystem (kernel, audio, the DCF stack split across `dcf-community-node`/`dcf-identity`/`dcf-tray`, agentic AI, secrets, etc.). Several directories are **self-contained sub-flakes with their own `flake.nix`** and source trees, not plain modules:

- `modules/greeting/` — Rust login greeter (Kitty graphics TUI). Exposes `nixosModules.greeting`.
- `modules/boot-intro/` — Rust boot-intro suite (GPU video gen, StreamDB). Exposes `boot-intro`/`-tui`/`-api` modules.
- `modules/blipply-assistant/` — Rust voice assistant (`src/` has audio STT/TTS/VAD, UI, ollama integration). Build/architecture docs live in its own `BUILD.md`/`ARCHITECTURE.md`.
- `modules/demod-voice/` — local TTS / voice cloning (Coqui XTTS-v2, Piper); `nixos-module.nix`.
- `modules/ArchibaldOS/` — the RT DSP guest OS, its own flake under `modules/ArchibaldOS/modules/`.

When changing one of these, build/iterate inside that sub-flake; the top-level flake consumes it as a pinned `path:` input.

### `vm-manager/`

A sub-flake providing two NixOS modules — `quickemu-vm` and `dsp-vm` — plus per-VM definitions in `vm-manager/config/` (DSP, coding sandbox, Kali, OpenWRT). The DSP VM is the latency-critical RT guest (NETJACK, isolated CPU core via `isolcpus=0`).

### `home/`

Home Manager user environment for `asher`. `home/home.nix` is the entrypoint; it builds a feature/profile set (`defaultFeatures`, `profiles/`) that gates desktop pieces, and a theme/palette system in `home/themes/` (the `p`/`activeTheme` shorthand seen throughout). Desktop config is split across `home/apps/` (KDE/Qt/GTK theming), `home/hyprland/`, `home/waybar/`, `home/x11/`, `home/terminal/`, `home/shell/`. Many `home/apps/*` modules take a `theme`/palette argument rather than reading global config.

## Conventions

- **Unfree + broken allowed.** `pkgsConfig` sets `allowUnfree = true` and `allowBroken = true`; builds may pull proprietary firmware/drivers (NVIDIA, etc.).
- **Pin everything through the flake.** New external dependencies become flake inputs, not ad-hoc fetches — the project explicitly avoids unpinned sources.
- **Secrets** use `sops-nix`. `secrets/` is git-ignored except `secrets/.sops.yaml`. Never commit decrypted material, `*.age`, or `secrets/secrets.yaml`.
- **State version is `25.11`** on `nixos-unstable`. Keep new modules consistent with that.

# AGENTS.md

NixOS distribution flake for Framework 16 AMD 7040. The build artifact is an OS (`nixosConfigurations.nixos`), not an app. Satire in `README.md` is not documentation. Map: `docs/architecture.md`. Outputs: `flake.nix`.

## Commands (repo root)

```bash
nix develop
nixpkgs-fmt <file.nix>          # subflakes; root formatter is nixfmt-rfc-style (`nix fmt`)
nix build .#nixosConfigurations.nixos.config.system.build.toplevel
sudo nixos-rebuild switch --flake .#nixos --impure
nix build .#iso
nix flake check                 # builds toplevel only; slow gates are packages
```

`--impure` is required when `~/.config/oligarchy/{local,state}.nix` exists. Pure eval silently uses fresh-clone defaults (steam, DSP, persona, etc.) instead of erroring.

Toggles live in `configuration.nix` (`custom.*` / `services.*`). Declaring modules default **off**; do not edit a module to “turn it on.”

## Where to read

| If you are changing | Start here | Dense? |
|---|---|---|
| Trust, W^X, install | `modules/oligarchy-plugins/` + `docs/plugins-roadmap.md` | yes |
| Substituter / NAR / peers | `modules/oligarchy-p2p/` + `docs/p2p-substituter-roadmap.md` | yes |
| Agent surface | `modules/mcp-servers/` + `docs/mcp-servers-roadmap.md` | yes |
| Egress / hardening | `modules/security/` | yes |
| DSP guest | `vm-manager/modules/dsp-vm.nix`, `modules/dsp-guest.nix` | medium |
| Desktop / theme | `home/` | no — large, not load-bearing |
| Host wiring | `flake.nix`, `configuration.nix` | medium |

Comments next to the code are load-bearing. A 400-line module is often 300 lines of mechanism. Do not “simplify” a comment you do not understand.

## Hard rules

1. **Nobody in `nix.settings.trusted-users`.** Root-equivalent. Plugins use `custom.plugins.installers` + signed cache. P2P daemon holds no key.
2. **P2P = availability, Nix = trust.** Never put `?trusted=1` on the substituter URI. Never let the adapter rewrite signed narinfo fields (`StorePath`, `NarHash`, `NarSize`, `References`).
3. **W^X is mirrored.** `Manifest::wx_enforced()` in `modules/oligarchy-plugins/host/src/manifest.rs` and `wxEnforced` in `modules/oligarchy-plugins/modules/plugins.nix`. Change both. `nix build .#plugins-wx-enforcement`.
4. **`nix store verify --sigs-needed 1` is not enough.** Content-addressed paths short-circuit; `nix store add-path` needs no privilege. Signature check must require a sig naming a `trustedPublicKeys` key *and* verify.
5. **MCP is stdio, read-only.** Reach CLIs only via `runner::run(ASPECT, prog, …)` (`modules/mcp-servers/crates/core/src/allowlist.rs`). No crate binds a socket except `ports-sec` (`allow-loopback-socket`). `nix build .#mcp-self-audit` fails if `.mcp.json` grows a URL/HTTP transport or if `dcf-mesh-mcp` / `demod-hypr-bridge` appear there.
6. **Read-write stays out of `.mcp.json`:** `oligarchy-forge`, `oligarchy-plugins`, `oligarchy-p2p`, `dsp-ctl`, `services.dcf-mesh-agent`, `services.dcf-hypr-agent`.
7. **Do not set `AQ_DRM_DEVICES` / `WLR_DRM_DEVICES` toward the dGPU.** No display path; Hyprland SIGABRTs. Client apps use `DRI_PRIME` (`custom.platform.displayGpu`). Assertion in `home/hyprland/default.nix`.
8. **Do not import HydraMesh `spa/modules/dcf-spa.nix`.** It sets `networking.nftables.enable` and fights `demod-ip-blocker`. Use `modules/security/dcf-spa-gate.nix`.
9. **New always-on service:** add a `lib.mkForce false` in the ISO block in `flake.nix` if the ISO should stay light. Plugins/P2P are imported on `nixosConfigurations.nixos` only.
10. **Secrets:** sops-nix. Never commit decrypted material, `*.age`, or `secrets/secrets.yaml`. Runtime paths only — a repo-relative env file copies into `/nix/store`.
11. **Pin via flake inputs**, not ad-hoc fetches. `allowUnfree = true`. Do not re-enable `allowBroken` (removed on purpose in `flake.nix`).
12. **DCF Docker images are `:latest` and off.** Do not enable `custom.dcfCommunityNode` / `custom.dcfIdentity` until those images are digests. Bind ports in `modules/hydramesh.nix` must match `modules/dcf-community-node.nix`.
13. **Path subflakes:** extra inputs in e.g. `modules/minecraft/flake.nix` are **not** passed by the parent lock (`flake.lock` `minecraft.inputs`). Prefer `fetchFromGitHub` inside the subflake, or `nix flake lock` at the repo root after adding inputs. `outputs = { self, nixpkgs, … }:` with new required args will eval-fail the whole OS.
14. **Do not `git add -A`.** Unstage `.hermes/`, tarballs, literal `~/` MCP audit dirs, `target/`.

## Adding an MCP aspect

Seven lists must agree (miss one → silent `exec failed`): `crates/core/src/allowlist.rs` (`ASPECTS` + `list_for`), `crates/umbrella/src/main.rs` (`is_known_aspect` + usage), `modules/mcp-servers/flake.nix` `aspectNames`, `modules/mcp-servers/nixos-module.nix` `aspectNames`, repo-root `.mcp.json`, `modules/mcp-servers/README.md`, `docs/architecture.md` §9. Copy `crates/hydramesh` or `crates/storage`. Tools must work **unprivileged**. Allowlist no deleting binaries.

## Gates (not in `nix flake check`; need KVM except mcp-self-audit)

```bash
nix build .#mcp-self-audit
nix build .#malwareScan
nix build .#plugins-wx-enforcement .#plugins-policy-refusal .#plugins-signed-install .#plugins-tier1-runtime
nix build .#plugins-tier2-runtime          # nested KVM
nix build .#p2p-substituter-protocol .#p2p-signature-refusal .#p2p-artifact-cache
nix build .#p2p-two-node .#p2p-swarm .#p2p-no-peer-fallback
nix build .#p2p-local-signing .#p2p-peer-scope .#p2p-selftest
cd modules/mcp-servers && cargo test --workspace
```

`tests/default.nix` is **not** a flake output. Eval directly if needed: `nix-build tests/default.nix -A strict-egress`.

Hosts: `nixos` (primary), `nixos-fw13` / `nixos-intel` / `nixos-optimus` (UUID stubs, unverified). User is `custom.user.name` (default `asher`).

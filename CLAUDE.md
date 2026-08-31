# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single Nix flake defining a complete NixOS distribution ("Oligarchy") targeting the **Framework 16 AMD 7040**. Configuration-as-code: five `nixosConfigurations` (`nixos` is the primary; `nixos-fw13`, `nixos-intel`, `nixos-optimus` are the alternate laptops; `builder` is the headless CI box), an installer ISO, twelve locally-vendored `path:` sub-flakes (several containing Rust programs), and a Home Manager user config. The build artifact is an OS — there is nothing to "run".

The README is heavy in-character satire ("war machine", fake legal decrees). Ignore the tone; the technical tables near the bottom, `flake.nix`, and `docs/architecture.md` are the source of truth.

Roughly **70k lines across 285 files** — 35k Nix, 25k Rust, 5k Shell. `docs/architecture.md` §1a has the per-language breakdown and, more usefully, which subsystems are dense versus merely large: `home/` is the biggest at 17k lines but is broad and mostly not load-bearing, while `oligarchy-p2p` and `oligarchy-plugins` (~9k each) are where the invariants live. Two things to expect when reading: **19% of the Nix and Rust is whole-line comments** (the reason a decision was made lives next to it, not only in a roadmap), and **14% of the Rust is `#[cfg(test)]`** — which still undercounts testing, because the expensive assertions are VM gates rather than unit tests.

## Where the docs are

`docs/` is the long form. This file states the rules; these state why, and are the place to read before a non-trivial change to the subsystem they cover.

| doc | covers |
|---|---|
| `architecture.md` | straight technical reference to the whole tree; §1a is the scale/density breakdown |
| `plugins-roadmap.md` | `oligarchy-plugins` design, staging record, per-stage known gaps. Superset of the plugin landmines below |
| `p2p-substituter-roadmap.md` | `oligarchy-p2p` design, trust argument, staging, known gaps. Superset of the p2p landmines below |
| `mcp-servers-roadmap.md` | the ten read-only MCP aspects; adding one |
| `oligarchy-forge-roadmap.md`, `oligarchy-forge-research.md` | forge design + roadmap (Phases 0-1 built), and the prior art it rests on |
| `security-hardening.md` | the hardening/egress/malware-shield posture |
| `dgpu-steam-forcing.md` | dGPU-vs-iGPU client rendering; why Hyprland's backend never moves |
| `secure-boot-enrollment.md`, `bios-uma-unlock.md` | firmware procedures — read before running either |
| `dcf-mesh-agent.md` | the read-write UDP mesh endpoint kept out of the MCP surface |

Subsystem READMEs carry the same role one level down: `modules/oligarchy-p2p/`, `modules/oligarchy-plugins/`, `modules/mcp-servers/`, `modules/demod-talk/`, `modules/minecraft/`, `modules/hypr-controller/`.

## Common commands

All commands run from the repo root.

```bash
# Enter the dev shell (Nix LSP `nil`, nixpkgs-fmt, qemu, virt-manager, network/debug tools)
nix develop

# Format Nix files. Use nixpkgs-fmt, NOT `nix fmt`: the flake's `formatter` is
# nixfmt-rfc-style, a different style that will reformat whatever it touches.
nixpkgs-fmt <file.nix>

# Evaluate/build the full system without switching (catches most errors).
# This builds the fresh-clone-minimal config (no local overrides visible
# without --impure — see below) — useful on its own for checking what a
# fresh clone actually gets. Add --impure to build asher's real personal
# config instead.
nix build .#nixosConfigurations.nixos.config.system.build.toplevel

# Apply the config to a running NixOS host. --impure is required on any
# machine with a ~/.config/oligarchy/{local,state}.nix override (see
# configuration.nix): those files live outside the repo on purpose, and pure
# evaluation (this system's default) cannot see them. Note the failure mode
# is SILENT, not loud: pure eval does not error on the pathExists guard, it
# answers false — Nix catches its own RestrictedPathError and returns false
# — so without --impure the personal toggles (steam, malware-shield, the DSP
# VM, persona, etc.) quietly fall back to their fresh-clone-minimal defaults.
# That silence is also what lets CI evaluate this flake on a machine that is
# not this one; see .github/workflows/eval.yml.
sudo nixos-rebuild switch --flake .#nixos --impure

# Build the installer ISO (the flake's default package)
nix build .#iso              # -> result/iso/nixos-*.iso

# Other package outputs (not gates)
nix build .#dsp-vm-qcow      # the DSP coprocessor guest image
nix run   .#oligarchy-hw-detect   # firmware/hardware check on an installed system

# Validate the flake. `checks.x86_64-linux.system` is the system toplevel, so
# this evaluates all outputs and builds the system.
nix flake check

# Update pinned inputs
nix flake update
```

### Build gates (run on demand)

```bash
nix build .#malwareScan             # YARA-scan the full system closure
nix build .#forge-catalog           # every forge agent still renders a flake that parses
nix build .#mcp-self-audit          # verify no MCP crate opens sockets / escapes its allowlist
nix build .#plugins-wx-enforcement  # boot a real kernel; assert the plugin tier/jit W^X split holds
nix build .#plugins-policy-refusal  # assert plugin policy refuses at install time, not at load time
nix build .#plugins-signed-install  # assert an unprivileged user can install a signed plugin and only a signed one
nix build .#plugins-tier1-runtime   # run a REAL native plugin; assert it observes the W^X its manifest declared
nix build .#plugins-tier2-runtime   # boot a real microVM; assert a self-JIT plugin gets W+X inside it and only inside it
nix build .#p2p-substituter-protocol # boot a VM; run a real substitution through the P2P adapter
nix build .#p2p-signature-refusal    # assert the adapter never becomes a trust authority
nix build .#p2p-artifact-cache       # assert the local artifact cache is real, verified, and used
nix build .#p2p-two-node             # two VMs; assert a host whose ONLY source is a peer gets the path
nix build .#p2p-swarm                # two VMs; assert artifacts move over BitTorrent, small ones do not
nix build .#p2p-no-peer-fallback     # assert P2P is an enhancement: no peers, build still works
nix build .#p2p-local-signing        # a host seeds what it BUILT; a consumer refuses it without the key
nix build .#p2p-peer-scope           # a peer key vouches only for the packages you named
nix build .#p2p-selftest             # the daemon's own assertions, AND that each one fails when broken
```

All are deliberately NOT in `checks` (they are slow — most need KVM, and tier2-runtime needs *nested* KVM — and `nix flake check` already builds the toplevel). They are separate `packages` outputs.

### Tests

NixOS VM integration tests live in `tests/default.nix` using `pkgs.testers.runNixOSTest`: `strict-egress`, `malware-shield`, `hardening`, `dcf-spa-gate`, `ip-blocklists`. They are exposed as `packages.test-<name>` and run like any other gate:

```bash
nix build .#test-strict-egress
```

**They are packages, not `checks`, deliberately.** `checks.x86_64-linux` holds only the system toplevel, which needs no KVM — that is what lets a runner without `/dev/kvm` still run `nix flake check`. Folding five VM tests into `checks` would silently take that property away.

The MCP server workspace has its own `cargo test --workspace` (52 unit tests, plus the `no_open_sockets` build gate in `crates/core/tests/`). Run from `modules/mcp-servers/`.

### CI

`.github/workflows/` — **every lane is disabled by default.** Nothing runs until `gh variable set OLIGARCHY_CI --body true`; the agent lane needs `OLIGARCHY_CI_AGENTS` on top, because it is the only one that costs money per run.

| lane | file | trigger | where |
|---|---|---|---|
| eval | `eval.yml` | push + PR, **incl. forks** | GitHub-hosted |
| gates | `gates.yml` | push to main, dispatch | self-hosted, on the host |
| nightly sweep | `gates.yml` | schedule | self-hosted, on the host |
| agents | `agents.yml` | PR (same-repo only), dispatch | self-hosted, in a microVM |

**The split is by trust, not convenience, and the repo being public is why.** A fork's pull request carries its own copy of `.github/workflows`, so any self-hosted job it can trigger is arbitrary code execution on the maintainer's LAN. `gates.yml` therefore has **no `pull_request` trigger at all** — do not add one — and every self-hosted job in `agents.yml` additionally requires `head.repo.full_name == github.repository`. That guard is on the *catalog* job too, which reads no diff and holds no key: it still runs `nix build` over checked-out source, and a Nix build executes that source's own build scripts.

The builder itself is `nixosConfigurations.builder` + `modules/ci-builder.nix` (`custom.ciBuilder.*`, off by default). Two things it must have: **nested KVM** (`plugins-tier2-runtime` boots a guest inside a guest — the module asserts on it, because without it the gate degrades to emulation and its boot budget stops measuring anything) and **disk** (`malwareScan` realizes the whole ~48.6 GiB closure). The nested-virt modprobe line is selected from `custom.platform.cpu` rather than hardcoded.

## Architecture

### Flake composition (`flake.nix`)

`nixosConfigurations.nixos` is assembled from three layers, in this order (order matters — option *declarations* must precede modules that *set* them):

1. **Third-party inputs** — `determinate`, `sops-nix`, `nixos-hardware` (the `framework-16-7040-amd` profile), `home-manager`, `nixos-generators`, `lanzaboote`, `demod-ip-blocker`, `hydramesh` (`github:ALH477/HydraMesh`, deliberately not following nixpkgs), `yara-rules` (`flake = false`). Note `fw-fanctrl` is **not** an input — that option comes from nixpkgs 25.11 now and is configured in `modules/platform.nix`.
2. **Home Manager** — `home-manager.nixosModules.home-manager`, with `users.asher = import ./home/home.nix`.
3. **Local `path:` sub-flakes + modules** — twelve sub-flakes (`greeting`, `boot-intro`, `blipply-assistant`, `vm-manager`, `mcp-servers`, `dsp-ctl`, `oligarchy-forge`, `oligarchy-plugins`, `oligarchy-p2p`, `demod-talk`, `demod-voice`, `minecraft`), plus the `./modules/*.nix` files and `./configuration.nix`. `oligarchy-plugins` and `oligarchy-p2p` are wired on the `nixos` host only; the rest are in `commonModules`. `demod-voice` is an input but is imported by plain path (`./modules/demod-voice/nixos-module.nix`).

`specialArgs` threads `inputs`, `nixpkgs-unstable`, `vm-manager`, `dsp-ctl`, `oligarchy-forge`, `mcp-servers`, `hydramesh`, and `demod-talk` into every module. The commented-out `archibaldos` input (`flake.nix:57-61`) is a placeholder for an external DSP coprocessor source; the DSP guest itself no longer waits on it (see `vm-manager/` below).

The **ISO** (`packages.x86_64-linux.iso`) is built separately via `nixos-generators` from a *reduced* module set layered on the upstream Calamares-Plasma6 installer. It force-disables the heavyweight production services with `lib.mkForce`: `ollamaAgentic`, `dcfCommunityNode`, `dcfIdentity`, `dcf-tray`, `strictEgress`, `blocklists`, `cpuSecurity`, `hardening`, `malwareShield`, `secrets`, `mcpServers`, `oligarchyForge`, `hydramesh`. When adding a new always-on service, check whether it also needs disabling here.

### `configuration.nix`

The central system module and the main place toggles are flipped. Most features are gated behind custom options and **default to off** in this file — enabling a feature usually means setting its `custom.*`/`services.*` option to `true` here, not editing the module. Option namespaces in play:

- `custom.*` — e.g. `custom.steam`, `custom.audio`, `custom.dcfCommunityNode`, `custom.dcfIdentity`, `custom.mcpServers`, `custom.malwareShield`, `custom.secrets`, `custom.secureBoot`, `custom.kernel.variant`. `custom.platform.*` (declared in `modules/platform.nix`, along with the fw-fanctrl config) is the hardware abstraction the hosts differ by: `gpu`, `cpu`, `framework`, and `displayGpu` — dGPU-vs-iGPU client-app rendering on dual-AMD hosts, which never routes Hyprland's own backend device to the dGPU (it has no display path and crashes the compositor; see `docs/dgpu-steam-forcing.md`). `custom.user.*` (`modules/user.nix`) and `custom.desktopFeatures.*` (`modules/desktop-features.nix`, gates `home/home.nix`) are what let a fresh clone default to something sane.
- `services.*` — project-defined services like `services.ollamaAgentic`, `services.dcf-tray`, `services.boot-intro`, `services.oligarchyGreeting`, `services.dsp-vm`.
- `networking.firewall.strictEgress` — the nftables egress firewall (`modules/security/strict-egress.nix`). Its `autoDetect.nixSubstituters` (default true) allows the hostname of every cache in `nix.settings.{substituters,trusted-substituters}`, so a module that adds a binary cache does not silently produce a firewall-blocked fetch. Derived from `nix.settings` rather than any one module's options, so it stays general and never references an option a given host may not declare.

`modules/security/` contributes six modules to `commonModules`: `strict-egress`, `dcf-spa-gate`, `ip-blocklists`, `hardening`, `malware-shield`, `security-cli`.

### `modules/`

Each `.nix` file declares the options + config for one subsystem (kernel, audio, platform, personas, the DCF stack split across `dcf-community-node`/`dcf-identity`/`dcf-tray`, agentic AI, secrets, etc.). `modules/dsp-rigs.nix` is "pedalboard as code" — switchable JACK effect chains. Several directories are **self-contained sub-flakes with their own `flake.nix`** and source trees, not plain modules:

- `modules/greeting/` — Rust login greeter (Kitty graphics TUI). Exposes `nixosModules.greeting`.
- `modules/boot-intro/` — Rust boot-intro suite (GPU video gen). Exposes `boot-intro`/`-tui`/`-api` modules. `modules/plymouth/` is the boot splash proper.
- `modules/blipply-assistant/` — Rust voice assistant (`src/` has audio STT/TTS/VAD, UI, ollama integration). Build/architecture docs live in its own `BUILD.md`/`ARCHITECTURE.md`.
- `modules/demod-voice/` — local TTS / voice cloning (Coqui XTTS-v2, Piper); `nixos-module.nix`.
- `modules/dsp-ctl/` — Rust TUI/CLI for the ArchibaldOS DSP VM (status, bench, start/stop).
- `modules/minecraft/` — Prism launcher plus unofficial Bedrock (`mcpelauncher`) built from the upstream manifests. `configuration.nix` installs `packages.default`. See `modules/minecraft/README.md`.
- `modules/mcp-servers/` — dedicated, read-only MCP servers (one Rust process per OS aspect + the `ports-sec` auditor, ten aspects). Exposes `nixosModules.default`. Full design + living roadmap: `docs/mcp-servers-roadmap.md`. Adding an aspect means editing seven hardcoded lists — the README's checklist enumerates them; `crates/storage` is the most recent worked example.
  - **Every tool must work unprivileged** — that is how this surface always runs, and the failures are silent. `nix-env --list-generations` on the *system* profile takes a write lock and dies "Permission denied"; `nix-collect-garbage --dry-run` as a non-root caller exits 0 having printed nothing. A tool that returns nothing looks like a healthy tool with nothing to say, so verify by driving the real server over stdio and comparing against a hand-made survey. → `modules/mcp-servers/README.md`
  - **`crates/storage`'s allowlist contains no binary capable of deleting, and that is structural.** Not a `--dry-run` constant a later edit could drop — generations are read straight off the profile symlinks, so `nix-env` and `nix-collect-garbage` are both absent from the list.
  - **`du` and `find` make path arguments a real injection surface even on a read-only aspect.** `runner::run` uses no shell, so quoting is not the risk — option parsing is: an argument beginning with `-` is read as a flag, and `find`'s flags include `-delete`. `checked_path` requires a leading `/`, which cannot be parsed as an option, and every call puts the path before any predicate.
- `modules/oligarchy-forge/` — sandboxed coding-agent runner: a TOML schema (`oligarchy-forge.toml`) compiles to a generated `flake.nix` building a `dockerTools.streamLayeredImage`, then runs it via rootless Podman (or Docker). CLI verbs `oligarchy-forge build/run/shell`; bare `oligarchy-forge` (or `oligarchy-forge tui`) launches a Ratatui session-list + live-build-log dashboard (`forge-tui` crate). `custom.oligarchyForge.enable`. Unlike `mcp-servers`, this is **not** part of the MCP surface — it's a normal read-write dev tool, same category as `dsp-ctl`. See `docs/oligarchy-forge-roadmap.md` (Phases 0-1 built; Phase 2 conflict resolution and Phase 3 skill browser/security tiers specced, not started).
- `modules/oligarchy-plugins/` — tiered sandboxed plugin runtime (`custom.plugins.*`), the foundation for the FX Bazaar. One WIT ABI (`oligarchy:plugin@0.1.0`) across three tiers: wasm (wasmtime + WASI), native/lua (bwrap + Landlock + seccomp) and microvm. Its point is **per-instance W^X**: `MemoryDenyWriteExecute` is decided per plugin from a `jit = none|host|self` manifest field, written into a systemd drop-in, not set once for the machine. Like `oligarchy-forge` and `dsp-ctl` this is **read-write** and must stay out of the MCP surface. Exposes `nixosModules.plugins`. **Staged:** all three tiers plus the signed imperative-install path are wired and gated, on `nixosConfigurations.nixos` only.

  Landmines, one line each. `docs/plugins-roadmap.md` is a strict superset of this list and carries the reasoning.
  - **The W^X rule lives in two places and they are a mirror** — `Manifest::wx_enforced()` (`host/src/manifest.rs`) and `wxEnforced` (`modules/plugins.nix`). Change one, change the other. Guard `.#plugins-wx-enforcement`.
  - **Nobody goes in `nix.settings.trusted-users`** — root-equivalent. The anchor is a signed cache + its key, every path `nix store verify`'d before registration. `custom.plugins.installers` exists so `trusted-users` need not: it adds an account to `installGroup`, which owns the control socket. → §5
  - **Unprivileged install goes through the control socket; the enforcement is structural.** `Request::Install` has no `allow_unsigned` field — unencodable, and `deny_unknown_fields` makes smuggling one a parse error (`host/src/control.rs`). `--allow-unsigned` is refused when `requireSignature` is true: policy outranks the CLI. Guard `Policy::authorize_signature`.
  - **`nix store verify --sigs-needed 1` is NOT a sufficient signature check** — Nix short-circuits for content-addressed paths and `nix store add-path` needs no privilege, so alone it accepts attacker-authored content as verified. `verify_signature` requires *both* a signature naming a `trusted_public_keys` entry *and* `nix store verify` accepting it; keys pinned via `NIX_CONFIG` (not `--option`, unusable by an untrusted client for a restricted setting); `nix build`/`nix store verify` run with privileges **dropped** to the state-dir owner, since `source` may be a flake ref and evaluating one as root is root code execution. All of it is `nix_cmd` in `host/src/registry.rs`. Easiest thing here to get wrong.
  - **Tier 1 (`native`/`lua`) is four settings that each break it silently** — `RestrictNamespaces` must list every namespace bwrap unshares (one `clone()`, so denying any fails all); `RestrictAddressFamilies` must include `AF_NETLINK`; `ProtectKernelTunables` must be **off**; `NotifyAccess` must be `all`. Per-instance drop-in, both mirrors. Guard `.#plugins-tier1-runtime`.
  - **`jit = "none"` is more than `MemoryDenyWriteExecute`, and getting it wrong is silent.** Also deny anonymous `PROT_EXEC`, `ptrace` and `userfaultfd` (each writes a page regardless of protection); drop-in carries `NoExecPaths=/ ${stateDir}` + `ExecPaths=/nix/store`, the state dir named **explicitly** because `StateDirectory=`'s bind mount comes back executable. Six routes, not two. → §4.1
  - **`plugind selftest` ships in release builds deliberately** — a filter that silently failed to install is invisible from inside the process that installed it.
  - **`${stateDir}/registry` is root-owned (`0750 root:oligarchy`)** — it feeds a drop-in generator root runs; every manifest read back is re-validated. A `Store` holds an flock spanning the `systemctl start`, or an `enable`/`disable` interleaving starts an instance under the template alone (no MDWE, `DevicePolicy=auto`).
  - **Tier 2 reaches its guest over AF_VSOCK, and how depends on the hypervisor** — cloud-hypervisor/firecracker use a userspace unix socket, qemu uses kernel `vhost-vsock` (dial the cid). `connect_guest` (`host/src/tiers/microvm.rs`) does both, `boot.kernelModules` needs `vhost_vsock`, and the cid comes from `declared.json` because only the module can keep cids unique. So a tier-2 drop-in grants `AF_UNIX AF_VSOCK` and **not** `PrivateNetwork=yes` — opposite of tiers 0/1, both mirrors. Vsock has no route off the machine.
  - **The guest's journal is a write-only hole** — journald output never reaches the console, so `modules/guest.nix` sets `StandardOutput=journal+console`. Grepping the host journal for a *unit name* also fails; the console carries its `Description`.
  - **A plugin is a control surface; `dsp` is an optional extension.** `world plugin` is control + lifecycle, `world plugin-dsp` adds `export dsp`. WIT has no optional exports, so `wasm.rs` runs `bindgen!` twice and instantiates the superset first — the failed attempt's error is discarded deliberately, and `Plugin::create_processor` returning `Ok(None)` is normal. → §4.2
  - **`/proc` in `forbiddenPaths` is W^X, not confidentiality** (the other six entries are). `/proc/<pid>/mem` writes use `FOLL_FORCE`, so a plugin can rewrite its own `.text`; seccomp cannot inspect path strings, so Landlock's allowlist is the only layer that can. Dropping `/proc` while tidying the secrets list weakens W^X without touching anything that looks like one. Guards `proc_is_refused_because_it_is_a_wx_bypass` (separate from `forbidden_paths_are_prefixes` so the failure names the guarantee) and `tests/wx-probe.c`, which probes seven routes and reports *which* layer refused (`EPERM` = seccomp, `EACCES` = Landlock).
  - **`declaredPlugins` is the only way a tier-2 plugin can exist** (a guest needs a closure, so a rebuild). `declared::resolve` cross-checks the module's `tier`/`jit` against the artifact's `plugin.toml` and refuses on disagreement — the drop-in was generated from the former before the latter was opened.
- `modules/oligarchy-p2p/` — the P2P substituter (`custom.p2pCache.*`): a loopback HTTP Nix binary-cache adapter so Nix can obtain NARs over a peer transport **without Nix being patched and without weakening its trust model**. Read-write and network-facing, so like `oligarchy-forge`/`oligarchy-plugins` it must stay out of the MCP surface. Exposes `nixosModules.p2pCache`. **Staged:** stage 6 is wired on `nixosConfigurations.nixos` only and **disabled by default**, with `transport` defaulting to `"none"` so enabling the adapter does not join a swarm, and `servePackages`/`trustedPublicKeys` defaulting to `[ ]` so it neither signs nor trusts anything.

  Landmines, one line each. `docs/p2p-substituter-roadmap.md` and `modules/oligarchy-p2p/README.md` carry the reasoning, except where marked.

  *Trust*
  - **`P2P provides availability. Nix provides trust.`** Daemon is unprivileged, holds no keys, cannot write the store; nix-daemon signature- and hash-checks every path afterwards. → §2
  - **`trustedPublicKeys` extends trust and Nix cannot scope it — so the adapter does.** `Priority: 30` puts the adapter ahead of cache.nixos.org for every path, so an unscoped compromised seeder could mint glibc and be believed. `acceptFromPeers` is **mandatory** whenever `trustedPublicKeys` is set (`["*"]` = explicit, warned opt-out). Guard `.#p2p-peer-scope`. → §2
  - **Scope rule is "does any `Sig:` name a peer key", NOT "name a key outside the peer set".** The second fails open: a junk `Sig: cache.nixos.org-1:AAAA` looks upstream-vouched, and `checkSignatures` *counts* verifying signatures rather than requiring all. Guard `appending_a_junk_upstream_signature_does_not_lift_the_scope`.
  - **A version suffix must begin with a digit** — `starts_with(entry + "-")` lets `glibc` reach `glibc-locales` and `linux` reach `linux-firmware`. `scope::in_scope`.
  - **Four enforcement points, each closing what the others cannot** — the transport loop (`LanTransport::narinfo` stops at the first parseable answer, so refusing only in the caller lets one hostile peer deny any path); `resolve`'s peer arm before persisting; `resolve`'s disk arm, since a narinfo in `narinfo/` is durable; `peer.rs`, so a lax host does not relay refused metadata onward. `declared/` is exempt everywhere.
  - **The scope check lives in the process the design calls hostile, and that costs less than it looks.** A compromised daemon holds no trusted private key, so RCE buys denial of service and request visibility, not forgery. Matters only against an attacker holding both a peer key and execution here. Clean fix = gap 38, deliberately not built.
  - **`?trusted=1` on a substituter URI would undo all of it** — Nix then accepts paths signed by no trusted key: exit 0, no warning, no runtime signal. Guarded three times because the failure is invisible: module assertion over every substituter, daemon config validation, and a `nix.conf` grep in `.#p2p-signature-refusal`.
  - **Content-addressed paths need no signature** — `checkSignatures` returns `maxSigs` without examining any. So `nix-store --add` output cannot test signature refusal, and the adapter's `NarHash` check adds nothing independent for CA paths.
  - **Prefer a package to a name in `acceptFromPeers`** — `[ pkgs.my-thing ]` renders to an exact store path at eval time; a bare name is matched against a name the *peer* supplied.

  *Signing and seeding*
  - **A host seeds what it BUILT via `servePackages`, and the key never touches the daemon.** Minting a narinfo needs the signing key *and* the Nix database; `oligarchy-p2pd` is denied both (no `AF_UNIX`, so it cannot reach nix-daemon). Minting is a separate root oneshot, `oligarchy-p2p-seed.service`; `signingKeyFile` is absent from the `config.json` the daemon reads. Do not fold the units together.
  - **Only paths with no signature at all are signed and published** — precisely the ones this host built. Signing the rest of a closure would put this host's name on glibc permanently in `/nix/var/nix/db`, travelling via `nix copy` and ssh-ng, and would let `declared/` (checked before `narinfo/`, never evicted) freeze the signature set of a path upstream also has.
  - **Nix does the crypto** — `nix store sign` / `nix path-info --sigs`, so `ValidPathInfo::fingerprint` is never reimplemented. `--json-format 1` is Determinate Nix 3.x only; `declared.rs` tries and falls back.
  - **`ReadOnlyPaths` for the declared tier needs the `-` prefix**, or systemd refuses to start the daemon when the directory is absent — an optional feature taking the substituter down.
  - **`oligarchy-p2p-selftest` runs as a UNIT sharing the daemon's sandbox verbatim.** `declared_refuses_a_write` proves `ReadOnlyPaths` by attempting a write; from a root shell that succeeds and reports a false PASS, so it SKIPs loudly there. Two rules from `mcp_self_audit`: a check that inspected nothing is a **FAIL**; a skipped check is reported, never omitted. `.#p2p-selftest` breaks each guarantee and asserts it is noticed.

  *The NAR path*
  - **The signature covers `StorePath`/`NarHash`/`NarSize`/`References` only**, which is why rewriting `URL`/`Compression`/`FileHash`/`FileSize` is legal. `NarInfo::set` asserts against `SIGNED_FIELDS`; rewriting a signed field surfaces far downstream as "lacks a signature by a trusted key".
  - **Nix imposes no upper bound on what a substituter delivers** — `FileSize` is never checked and trailing bytes are discarded silently; 64 MiB against a 279 KiB claim registers the path valid. The adapter's byte cap is the only bound.
  - **A digest check written after the read loop does not run.** `Body::from_stream` with `Content-Length` drops the generator once it has enough bytes, so a length-preserving corruption serves HTTP 200. `verifying_stream` withholds the final chunk until `finish()` passes. Guards `a_corrupt_body_never_completes` + the journal assertion in `.#p2p-signature-refusal`.
  - **Serve the canonical UNCOMPRESSED NAR — correctness, not preference.** Nix caches a narinfo 30 days and cache.nixos.org re-compresses, so a `FileHash`-derived URL with a compression suffix made every cached narinfo name a NAR the adapter refused, 404ing for a month. Now `Compression: none`, `FileHash = NarHash`, `FileSize = NarSize`, `URL = nar/<hashpart>/<narhash>.nar` — every field a function of signed, immutable data. Guard `the_nar_url_does_not_move_when_upstream_recompresses`. → §3.2
  - **The narinfo is cached on disk, and that is what makes the artifact cache work at all** — a NAR request resolves its narinfo first, so when that went to the network a full cache answered 404 the moment upstream was unreachable. `<stateDir>/narinfo/` has its **own** eviction budget, deliberately not shared with the NAR budget.
  - **Local sources are read twice on purpose.** The cache and `nix-store --dump` hash the artifact in full before opening the response, so a tampered artifact 404s and Nix never sees a byte. The upstream first-fetch cannot: Nix aborts a transfer delivering nothing for `stalled-download-timeout` (300s), so buffering a multi-gigabyte NAR would make large paths impossible — it uses a one-chunk lookahead. *(Recorded nowhere else.)*
  - **Nothing is named until it is verified.** Writes land in `<stateDir>/tmp/` and are `rename`d into `nar/` only after the digest matches; `Slot`'s `Drop` removes an uncommitted temp, `Cache::new` sweeps `tmp/` at startup. Both directories must stay on one filesystem — `rename(2)`'s atomicity is the guarantee. *(`Slot::Drop` and the one-filesystem rule recorded nowhere else.)*
  - **`serveFromStore` uses `nix-store --dump`, the old CLI, deliberately** — it serialises a directory and consults nothing else, so the daemon needs no Nix database and never opens the nix-daemon socket, which is why `RestrictAddressFamilies` stays `AF_INET AF_INET6`. It never asks whether a path is *valid*; output is hashed against the signed `NarHash`, so invalid debris fails and falls through. *(Recorded nowhere else.)*

  *Peers and transport*
  - **TWO listeners, and the separation is the design.** The substituter surface is loopback-only and proxies anything its upstreams hold — exposing it would publish an open proxy for all of cache.nixos.org. The peer surface (`custom.p2pCache.peer`, default off, port 5112) binds a real interface and answers only *do you already have this?*: never an upstream fetch on a peer's behalf, nothing unverified, its own route set. Reach via `peer.openFirewall`, empty by default.
  - **Peer addresses are restricted to private ranges in code**, not left to the firewall — RFC1918 / CGNAT / link-local is exactly what `strict-egress.nix` already allows, so a LAN swarm needs no egress change. A public entry is dropped with a loud log, not fatally.
  - **Peers supply metadata as well as bytes, and must** — a NAR cannot be verified without the signed `NarHash`, so without a peer narinfo leg the transport is useless offline. Upstream's narinfo returns verbatim, signature intact; `LanTransport::narinfo` re-checks it names the path asked for.
  - **A peer fetch is verified in full before anything is served**, unlike the upstream path — peers are the untrusted source that most deserves the stronger guarantee.
  - **A peer seeds what it FETCHED, not what it built** — `GET /peer/v1/narinfo/<hp>` answers only from the on-disk narinfo cache, so a locally-built path cannot be seeded at all. Hence `.#p2p-two-node` warms its seeder with a real substitution.
  - **Testing a peer transport is where vacuous tests come from.** Test nodes share the *host's* `/nix/store`, so a leecher sees artifacts it does not have and `serveFromStore` bypasses the transport. Corrupting an honest seeder's cache proves only that the seeder refuses first. Proving a leecher refuses a lying peer needs a genuinely hostile peer — `.#p2p-two-node` ships one as a `writeText` derivation.
  - **BitTorrent discovery is not BitTorrent's** — `disable_dht: true`, no trackers, no PEX; peers *and* infohashes come from the peer surface, since every address dialled must be in the private-range list to work under `strict-egress` unchanged. Adds nothing to trust: piece hashes come from an untrusted peer's `.torrent`, so the file is still hashed against the signed `NarHash`. Guard `.#p2p-swarm`.
  - **A transport method must never block, with two distinct failure modes** — `Handle::block_on` from an async handler panics; from a `spawn_blocking` thread it never returns at all, leaving a healthy-looking daemon. `provide`/`remove` spawn onto the runtime and return; `remove` then has no ordering guarantee against eviction, which librqbit survives. Guard `.#p2p-swarm`.
  - **`minArtifactSize` (default 4 MiB) is checked in `discover`, before any peer is contacted.** Median NAR here is 355 KiB; 4 MiB puts 16.4% of paths in swarms covering 96.0% of bytes. Checking in `fetch` would cost a round trip on every small path. *(Call-site placement recorded nowhere else.)*
  - **A host seeds at every point an artifact becomes a cache entry** — upstream fetch, `nix-store --dump`, peer fetch — and re-announces at startup, since a restart otherwise silently stops seeding everything while looking healthy.
  - **The daemon's user is a static system user, not `DynamicUser`** — `strict-egress`'s `allow.uids` matches `meta skuid "<name>"` against passwd at ruleset-load time and cannot name a runtime-allocated uid.
- `modules/ArchibaldOS/` — the RT DSP guest OS, its own flake under `modules/ArchibaldOS/modules/`.

When changing one of these, build/iterate inside that sub-flake; the top-level flake consumes it as a pinned `path:` input.

`modules/hypr-controller/` is a different shape — not a sub-flake. `nixos-module.nix` + `hypr_bridge.py` declare `services.dcf-hypr-agent` (a DCF-Hypr bridge that relays Hyprland IPC + an `oligarchy-ctl` passthrough over UDP to the `android/` companion app, a plain Gradle/Kotlin project with no Nix build of its own). It's imported directly by `configuration.nix` next to `./modules/dcf-mesh-agent.nix`, off by default, and — like `dcf-mesh-agent` — is deliberately **not** part of the read-only MCP surface (`mcp_self_audit` fails the build if it ends up in `.mcp.json`). See `modules/hypr-controller/README.md`.

Its `spaGated` option pulls in `modules/security/dcf-spa-gate.nix` (`networking.firewall.spaGate`). **Do not "simplify" that by importing HydraMesh's own `spa/modules/dcf-spa.nix`** — upstream sets `networking.nftables.enable`, which switches the global firewall backend and fails eval against `demod-ip-blocker`'s ipset/iptables `extraCommands`. Like `strict-egress.nix`, the gate ships a self-contained `inet` table loaded by its own oneshot service so it coexists with the iptables firewall; its chain is `policy accept` (only the gated port is dropped) rather than upstream's whole-system `policy drop`. Only upstream's `dcf-spa-authorizer` *binary* is reused. `tests/default.nix -A dcf-spa-gate` guards all of this.

### `vm-manager/`

A sub-flake providing two NixOS modules — `quickemu-vm` and `dsp-vm` — plus per-VM definitions in `vm-manager/config/` (DSP, coding sandbox, Kali, OpenWRT). The DSP VM is the latency-critical RT guest (NETJACK, isolated CPU core via `isolcpus=0`).

**The DSP guest is code now.** `modules/dsp-guest.nix` defines it and `nix build .#dsp-vm-qcow` builds the image, wired into `custom.vm.dsp.archibaldOS.diskImage`. It used to be a hand-copied qcow2 built out-of-tree — three files in this repo *looked* like they defined it and none did, so when the image stopped booting there was nothing to rebuild it from. Two traps the file records: the format must be **`qcow-efi`, not `qcow`** (the firmware is OVMF; a BIOS image has no ESP, so OVMF finds nothing and falls through to a PXE netboot loop — silently reproducing the original failure), and `modules/archibaldos-dsp-vm.nix` stays **unimported** because it would declare a second unit claiming the same xHCI functions, failing with a device-busy error that reads like a hardware fault.

### `home/`

Home Manager user environment for `asher`. `home/home.nix` is the entrypoint; it builds a feature/profile set (`defaultFeatures`, `profiles/`, gated by `custom.desktopFeatures.*`) and a theme/palette system in `home/themes/` (the `p`/`activeTheme` shorthand seen throughout). Desktop config is split across `home/apps/` (KDE/Qt/GTK theming), `home/hyprland/`, `home/waybar/`, `home/x11/`, `home/terminal/`, `home/shell/`. Many `home/apps/*` modules take a `theme`/palette argument rather than reading global config.

### `scripts/`

Standalone operator scripts, not wired into any derivation: `dsp-latency-guest.sh` / `dsp-latency-loopback.sh` (DSP latency harnesses), `usb-audio-stress.sh`, `usb-xhci-watch.sh`, `xhci-recover.sh`.

## Conventions

- **Unfree allowed; broken is NOT.** `pkgsConfig` sets `allowUnfree = true` and `permittedInsecurePackages = [ ]`. `allowBroken` was **deliberately removed** — it silently lets known-broken packages into the closure on a production machine. Do not re-add it; override per-package if ever needed.
- **`nix fmt` is not the project formatter.** The flake's `formatter` is `nixfmt-rfc-style`, but the tree is written in `nixpkgs-fmt`. Format with `nixpkgs-fmt <file.nix>`, and don't blanket-format files you didn't touch.
- **Pin everything through the flake.** New external dependencies become flake inputs, not ad-hoc fetches — the project explicitly avoids unpinned sources.
- **Secrets** use `sops-nix`. `secrets/` is git-ignored except `secrets/.sops.yaml`. Never commit decrypted material, `*.age`, or `secrets/secrets.yaml`.
- **State version is `25.11`** on `nixos-25.11` (nixpkgs stable). Keep new modules consistent with that. `nixpkgs-unstable` is available via the `unstable` overlay for cherry-picks.
- **MCP servers are read-only + dry-run by construction.** The agent surface can never mutate the running system. Each aspect server has a per-aspect CLI allowlist (`modules/mcp-servers/crates/core/src/allowlist.rs`) enforced at runtime by `runner::run` — reach CLIs only through it, never via a bare `Command::new`. The `ports-sec` crate is the only one permitted to open sockets (loopback-only, feature-gated). `nix build .#mcp-self-audit` enforces the socket rule and checks `.mcp.json` for remote transports at the project level.
- `modules/demod-talk/` — DCF-Talk sub-flake: the pure-Lua DCF chat stack (certified text + Snake adapters, voice L3 with jitter/PLC/DTX, SuperPack + Reed-Solomon transport, StreamDB history). `services.demod-talk.enable`, **off by default**. Plaintext by design — DCF carries no encryption to stay clear of EAR/ITAR — so `interface` is mandatory with no default, the firewall opens on that interface only, and an assertion fails the build if it is not a WireGuard interface declared on this host (unless an over-the-air transport is chosen, where plaintext is lawful and expected). The package's `checkPhase` runs all six golden-vector certifications plus four smoke modes, so a failed certification is a failed build. Ships `dcf-talk`, `dcf-jam`, `dcf-certify`. See `modules/demod-talk/README.md`.
- **HydraMesh is a hard requirement of the distro,** not an optional feature: `modules/hydramesh.nix` (`custom.hydramesh.enable`) defaults to **true** and installs the `hydramesh` / `dcf` SDK CLIs plus the HydraModem toolbox. The ISO force-disables it. `services.dcf-mesh-agent` is a separate, read-write, UDP-bound Python endpoint that is deliberately NOT part of the MCP surface and must stay out of `.mcp.json`.

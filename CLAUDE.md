# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A single Nix flake that defines a complete NixOS distribution ("Oligarchy") targeting the **Framework 16 AMD 7040**. It is configuration-as-code: there is one main system (`nixosConfigurations.nixos`), an installer ISO, several locally-vendored sub-flakes (some containing Rust programs), and a Home Manager user config. There is no traditional application to "run" — the build artifact is an OS.

The README is written in heavy in-character satire ("Oligarchy", "war machine", fake legal decrees). Ignore the tone; the technical tables near the bottom, the `flake.nix`, and `docs/architecture.md` are the source of truth.

## Common commands

All commands run from the repo root.

```bash
# Enter the dev shell (Nix LSP `nil`, nixpkgs-fmt, qemu, virt-manager, network/debug tools)
nix develop

# Format Nix files
nixpkgs-fmt <file.nix>

# Evaluate/build the full system without switching (catches most errors).
# This builds the fresh-clone-minimal config (no local overrides visible
# without --impure — see below) — useful on its own for checking what a
# fresh clone actually gets. Add --impure to build asher's real personal
# config instead.
nix build .#nixosConfigurations.nixos.config.system.build.toplevel

# Apply the config to a running NixOS host. --impure is required on any
# machine with a ~/.config/oligarchy/{local,state}.nix override (see
# configuration.nix): those files live outside the repo on purpose, and
# checking whether an ambient filesystem path exists is exactly what pure
# evaluation (this system's default) disallows. Without it, personal
# toggles (steam, malware-shield, the DSP VM, persona, etc.) silently fall
# back to their fresh-clone-minimal defaults instead of erroring.
sudo nixos-rebuild switch --flake .#nixos --impure

# Build the installer ISO (the flake's default package)
nix build .#iso          # -> result/iso/nixos-*.iso

# Validate the flake (eval all outputs)
nix flake check

# Update pinned inputs
nix flake update
```

### Build gates (run on demand)

```bash
nix build .#malwareScan             # YARA-scan the full system closure
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
```

All are deliberately NOT in `checks` (they are slow — most need KVM, and tier2-runtime needs *nested* KVM — and `nix flake check` already builds the toplevel). They are separate `packages` outputs.

### Tests

NixOS VM integration tests live in `tests/default.nix` using `pkgs.testers.runNixOSTest` (e.g. the `strict-egress` firewall test). **Note:** these are not currently wired into the flake's `outputs` (no `checks`/`packages.test` attribute exists despite the dev-shell banner mentioning `nix run .#test`). To run one, either add it to flake outputs or evaluate it directly, e.g.:

```bash
nix-build tests/default.nix -A strict-egress   # or wire into flake checks first
```

The MCP server workspace has its own `cargo test --workspace` (34 unit tests incl. the `no_open_sockets` build gate). Run from `modules/mcp-servers/`.

## Architecture

### Flake composition (`flake.nix`)

`nixosConfigurations.nixos` is assembled from three layers, in this order (order matters — option *declarations* must precede modules that *set* them):

1. **Third-party modules** — `determinate`, `sops-nix`, `nixos-hardware` (the `framework-16-7040-amd` profile), `fw-fanctrl`, `demod-ip-blocker`.
2. **Home Manager** — `home-manager.nixosModules.home-manager`, with `users.asher = import ./home/home.nix`.
3. **Local modules + sub-flakes** — the `boot-intro`, `greeting`, `blipply-assistant`, `vm-manager`, `demod-voice`, `dsp-ctl`, and `mcp-servers` sub-flakes (referenced as `path:./...` flake inputs), plus the `./modules/*.nix` files and `./configuration.nix`.

`specialArgs` threads `inputs`, `nixpkgs-unstable`, `vm-manager`, `dsp-ctl`, and `mcp-servers` into every module. The commented-out `archibaldos` input is the pattern for adding the external DSP coprocessor when available.

The **ISO** (`packages.x86_64-linux.iso`) is built separately via `nixos-generators` from a *reduced* module set layered on the upstream Calamares-Plasma6 installer. It force-disables the heavyweight production services (`ollamaAgentic`, `dcfCommunityNode`, `dcfIdentity`, `dcf-tray`, `strictEgress`, `cpuSecurity`, `hardening`, `malwareShield`, `secrets`, `mcpServers`) with `lib.mkForce`. When adding a new always-on service, check whether it also needs disabling here.

### `configuration.nix`

The central system module and the main place toggles are flipped. Most features are gated behind custom options and **default to off** in this file — enabling a feature usually means setting its `custom.*`/`services.*` option to `true` here, not editing the module. Option namespaces in play:

- `custom.*` — e.g. `custom.steam`, `custom.audio`, `custom.dcfCommunityNode`, `custom.dcfIdentity`, `custom.mcpServers`, `custom.malwareShield`, `custom.secrets`, `custom.secureBoot`, `custom.kernel.variant`, `custom.platform.gpu`, `custom.platform.displayGpu` (dGPU-vs-iGPU client-app rendering on dual-AMD hosts — never routes Hyprland's own backend device to the dGPU, which has no display path and crashes the compositor if you try; see `docs/dgpu-steam-forcing.md`).
- `services.*` — project-defined services like `services.ollamaAgentic`, `services.dcf-tray`, `services.boot-intro`, `services.oligarchyGreeting`, `services.dsp-vm`.
- `networking.firewall.strictEgress` — the nftables egress firewall (`modules/security/strict-egress.nix`). Its `autoDetect.nixSubstituters` (default true) allows the hostname of every cache in `nix.settings.{substituters,trusted-substituters}`, so a module that adds a binary cache does not silently produce a firewall-blocked fetch. Derived from `nix.settings` rather than any one module's options, so it stays general and never references an option a given host may not declare.

### `modules/`

Each `.nix` file declares the options + config for one subsystem (kernel, audio, the DCF stack split across `dcf-community-node`/`dcf-identity`/`dcf-tray`, agentic AI, secrets, etc.). Several directories are **self-contained sub-flakes with their own `flake.nix`** and source trees, not plain modules:

- `modules/greeting/` — Rust login greeter (Kitty graphics TUI). Exposes `nixosModules.greeting`.
- `modules/boot-intro/` — Rust boot-intro suite (GPU video gen). Exposes `boot-intro`/`-tui`/`-api` modules.
- `modules/blipply-assistant/` — Rust voice assistant (`src/` has audio STT/TTS/VAD, UI, ollama integration). Build/architecture docs live in its own `BUILD.md`/`ARCHITECTURE.md`.
- `modules/demod-voice/` — local TTS / voice cloning (Coqui XTTS-v2, Piper); `nixos-module.nix`.
- `modules/dsp-ctl/` — Rust TUI/CLI for the ArchibaldOS DSP VM (status, bench, start/stop).
- `modules/mcp-servers/` — dedicated, read-only MCP servers (one Rust process per OS aspect + the `ports-sec` auditor). Exposes `nixosModules.default`. See `docs/mcp-servers-roadmap.md` for the full design + living roadmap. Adding an aspect means editing seven hardcoded lists — the README's checklist enumerates them; `crates/hydramesh` is the worked example.
- `modules/oligarchy-forge/` — sandboxed coding-agent runner: a TOML schema (`oligarchy-forge.toml`) compiles to a generated `flake.nix` building a `dockerTools.streamLayeredImage`, then runs it via rootless Podman (or Docker). CLI verbs `oligarchy-forge build/run/shell`; bare `oligarchy-forge` (or `oligarchy-forge tui`) launches a Ratatui session-list + live-build-log dashboard (`forge-tui` crate). `custom.oligarchyForge.enable`. Unlike `mcp-servers`, this is **not** part of the MCP surface — it's a normal read-write dev tool, same category as `dsp-ctl`. See `docs/oligarchy-forge-roadmap.md` for the full design + living roadmap (Phases 0-1 built; Phase 2 conflict resolution and Phase 3 skill browser/security tiers are specced but not started).
- `modules/oligarchy-plugins/` — tiered sandboxed plugin runtime (`custom.plugins.*`), the foundation for the FX Bazaar. One WIT ABI (`oligarchy:plugin@0.1.0`) across three tiers: wasm (wasmtime + WASI), native/lua (bwrap + Landlock + seccomp) and microvm. Its point is **per-instance W^X**: `MemoryDenyWriteExecute` is decided per plugin from a `jit = none|host|self` manifest field, written into a systemd drop-in, not set once for the machine. Like `oligarchy-forge` and `dsp-ctl` this is a **read-write** tool and must stay out of the MCP surface. Exposes `nixosModules.plugins`. **Staged:** all three tiers plus the signed imperative-install path are wired and gated, on `nixosConfigurations.nixos` only. See `docs/plugins-roadmap.md` for the staging record and the known gaps per stage.
  - The W^X rule lives in **two** places on purpose — `Manifest::wx_enforced()` in `host/src/manifest.rs` and `wxEnforced` in `modules/plugins.nix`. They are a mirror; change one and you must change the other. `nix build .#plugins-wx-enforcement` boots a real kernel and asserts they agree.
  - Nobody goes in `nix.settings.trusted-users`. Per the Nix manual that is root-equivalent; the trust anchor is a signed cache in `substituters`/`trusted-substituters` plus its key, with every path `nix store verify`'d before registration. `custom.plugins.installers` is the option that exists so `trusted-users` does not have to be — it adds an account to `installGroup`, which owns the control socket.
  - **Unprivileged install goes through the control socket, and the enforcement is structural.** `plugind` forwards registry-mutating verbs to the root supervisor when the caller cannot write the registry (`host/src/control.rs`). `Request::Install` has no `allow_unsigned` field — not ignored, *unencodable* — and `deny_unknown_fields` makes an attempt to smuggle it a parse error. Separately, `--allow-unsigned` on the direct path is **refused** when `requireSignature` is true: policy outranks the CLI, or the declarative half would be advisory. `Policy::authorize_signature` is that rule, unit-tested as a table.
  - **`nix store verify --sigs-needed 1` is NOT a sufficient signature check, and this is the easiest thing here to get wrong.** Nix short-circuits verification for content-addressed paths, and `nix store add-path` needs no privilege — so on its own it accepts arbitrary attacker-authored content as verified. `verify_signature` requires *both* a signature present naming a key from `policy.trusted_public_keys` *and* `nix store verify` accepting it. The key set is pinned via `NIX_CONFIG` (not `--option`, which an untrusted client cannot use for a restricted setting). `nix build`/`nix store verify` also run with privileges **dropped** to the state-dir owner: `source` may be a flake ref, and evaluating one as root is root code execution. All of it is one function, `nix_cmd` in `host/src/registry.rs`.
  - **Tier 1 (`native`/`lua`) is a stack of settings that each break it silently.** `RestrictNamespaces` must list every namespace bwrap unshares (it does them in one `clone()`, so denying any fails all and bwrap blames `unprivileged_userns_clone`); `RestrictAddressFamilies` must include `AF_NETLINK` (bwrap brings up loopback); `ProtectKernelTunables` must be **off** (a locked submount under `/proc` makes `mount("proc")` in a userns EPERM); and `NotifyAccess` must be `all` (MainPID is bwrap, but the shim it forks is what becomes ready — otherwise the unit burns `TimeoutStartSec` while the plugin logs "ready"). All four live in the per-instance drop-in, in both mirrors. `nix build .#plugins-tier1-runtime` runs a real `.so` that probes the sandbox from inside and catches every one of them.
  - **`jit = "none"` is more than `MemoryDenyWriteExecute`, and getting that wrong is silent.** An adversarial review broke it three ways on real hardware: `ptrace(POKEDATA)` and `userfaultfd` write a page regardless of its protection, and the mmap rule only fired on `PROT_WRITE|PROT_EXEC` *together* — so an anonymous exec-only mapping was a free target; and the plain-file dual mapping worked because `seccomp.rs` asserted writable mounts must be noexec and nothing implemented it. The filter now denies anonymous `PROT_EXEC`, `ptrace` and `userfaultfd`, and the drop-in carries `NoExecPaths=/ ${stateDir}` + `ExecPaths=/nix/store` — the state dir named **explicitly**, because `StateDirectory=`'s own bind mount comes back executable otherwise. Both probes test six routes now: the old two-route version reported "denied" while three were open.
  - `plugind selftest` is the real-hardware W^X proof and is available in **release** builds deliberately: it installs the filter in a forked child and attempts `mprotect(PROT_EXEC)` and `memfd_create`. A filter that silently failed to install is invisible from inside the process that installed it.
  - `${stateDir}/registry` is **root-owned** (`0750 root:oligarchy`) because it is the input to a drop-in generator that root runs; every manifest read back out of it is re-validated. A `Store` holds an flock for its lifetime, spanning the `systemctl start`, because an `enable`/`disable` interleaving otherwise starts an instance under the template alone — no MDWE, `DevicePolicy=auto`.
  - **Tier 2 reaches its guest over AF_VSOCK, and how depends on the hypervisor.** cloud-hypervisor and firecracker implement vsock in userspace behind a unix socket; qemu uses the kernel's `vhost-vsock`, where there is no socket file and you dial the cid. `connect_guest` in `host/src/tiers/microvm.rs` does both, `boot.kernelModules` gets `vhost_vsock`, and the cid comes from `declared.json` because only the module can keep cids unique. Consequently a tier-2 plugin's drop-in must grant `AF_UNIX AF_VSOCK` and **not** `PrivateNetwork=yes` — the opposite of tiers 0/1, in both mirrors. Nothing is widened outward: vsock has no route off the machine.
  - **The guest's journal is a write-only hole.** It lives in a disposable VM nobody can log into, and journald output does not reach the console even though systemd's own status lines do. `modules/guest.nix` sets `StandardOutput=journal+console` so a plugin's own log reaches the host's `microvm@<id>.service`. Debugging a guest by grepping the host journal for a *unit name* does not work either — the console carries its `Description`.
  - **A plugin is a control surface; `dsp` is an optional extension.** Realtime audio belongs to the **RT VM engine** (ArchibaldOS DSP guest — isolated core, RT kernel, NETJACK), not to a Landlock-confined plugin process. The ABI originally mandated `export dsp`, which made every plugin an audio effect and forced `tests/wx-probe.c` (a *sandbox* probe) to carry a stub `process()`. Now: `world plugin` is control + lifecycle, `world plugin-dsp` is `include plugin` + `export dsp`, and the C side reaches audio through `get_extension(OLIGARCHY_EXT_DSP)`. **WIT has no optional exports**, so `wasm.rs` runs `bindgen!` twice and discovers which world a component satisfies by instantiating the superset first — the failed attempt's error is discarded deliberately, because control-only is the normal case. `Plugin::create_processor` returning `Ok(None)` is likewise normal, not a fault. See `docs/plugins-roadmap.md` §4.2.
  - **`forbiddenPaths` holds two different guarantees, and `/proc` is the odd one out.** Six entries are confidentiality (ssh, shadow, sops, secrets, `/root`, `/home`); `/proc` is **W^X**. Writes through `/proc/<pid>/mem` use `FOLL_FORCE`, so a plugin can rewrite its own `.text` and `jit = "none"` stops meaning anything — and seccomp cannot close that route, because it cannot inspect path strings. Landlock's deny-by-default allowlist is the only layer that can, and only while nothing is granted a path under `/proc`. Dropping `/proc` while tidying the secrets list weakens W^X without touching anything that looks like a W^X setting; `proc_is_refused_because_it_is_a_wx_bypass` is a separate test from `forbidden_paths_are_prefixes` so the failure names the guarantee. `tests/wx-probe.c` probes seven routes and reports *which* layer refused (`EPERM` = seccomp, `EACCES` = Landlock), because "denied" alone cannot tell you whether the control you think is working is the one that fired.
  - **`declaredPlugins` is the only way a tier-2 plugin can exist** (a guest needs a closure, so it needs a rebuild). `declared::resolve` cross-checks the module's `tier`/`jit` against the artifact's own `plugin.toml` and refuses on disagreement, because the sandbox drop-in was generated from the former before the latter was ever opened.
- `modules/oligarchy-p2p/` — the P2P substituter (`custom.p2pCache.*`): a loopback HTTP Nix binary-cache adapter so Nix can obtain NARs over a peer transport **without Nix being patched and without weakening its trust model**. Read-write and network-facing, so like `oligarchy-forge`/`oligarchy-plugins` it must stay out of the MCP surface. Exposes `nixosModules.p2pCache`. **Staged:** stage 4 (BitTorrent over the LAN peer surface) is wired on `nixosConfigurations.nixos` only and **disabled by default**, with `transport` defaulting to `"none"` so enabling the adapter does not join a swarm. See `docs/p2p-substituter-roadmap.md`.
  - **The rule is `P2P provides availability. Nix provides trust.`** The daemon is unprivileged, holds no keys, cannot write the store, and every path it serves is signature- and hash-checked by nix-daemon afterwards. Peers are sources of bytes and nothing else.
  - **`?trusted=1` on a substituter URI is the one change that would undo all of it.** It makes Nix accept paths signed by no trusted key — verified on real hardware: exit 0, no warning, no diagnostic, no runtime signal. Guarded in three places (module assertion scanning every substituter on the host, daemon config validation, and a grep of the generated `nix.conf` in `.#p2p-signature-refusal`) precisely because the failure is invisible.
  - **The signature covers `StorePath`/`NarHash`/`NarSize`/`References` and nothing else** (`ValidPathInfo::fingerprint`), which is why rewriting `URL`/`Compression`/`FileHash`/`FileSize` is legal. `NarInfo::set` asserts against `SIGNED_FIELDS` rather than trusting the caller — rewriting a signed field would invalidate every `Sig` and surface far downstream as an unexplained "lacks a signature by a trusted key".
  - **Nix imposes no upper bound on what a substituter delivers.** `FileSize` is never checked on the substitution path and bytes past the end of the NAR stream are read and discarded silently — serving 64 MiB against a 279 KiB claim succeeds and registers the path valid. The adapter's byte cap is the only bound that exists; do not "simplify" it away.
  - **A digest check written after the read loop does not run.** `Body::from_stream` with `Content-Length` set makes the HTTP layer drop the generator once it has enough bytes, so the post-loop check is skipped and a length-preserving corruption is served with HTTP 200. `verifying_stream` withholds the final chunk until `finish()` passes; `a_corrupt_body_never_completes` and the journal assertion in `.#p2p-signature-refusal` both exist because "the build failed" alone would pass against the broken version.
  - **The adapter serves the canonical UNCOMPRESSED NAR, and that is a correctness fix rather than a preference.** Stage 1 passed upstream's compressed bytes through and keyed the URL on `FileHash` + the compression suffix — both of which describe bytes upstream controls. Nix caches a narinfo for `narinfo-cache-positive-ttl` (**30 days**), and cache.nixos.org demonstrably re-compresses (it moved `hello` from xz to zstd mid-development), so every cached narinfo then named a NAR the adapter refused and it 404'd for a month. Now `Compression: none`, `FileHash = NarHash`, `FileSize = NarSize`, `URL = nar/<hashpart>/<narhash>.nar` — every emitted field is a function of signed, immutable data. `the_nar_url_does_not_move_when_upstream_recompresses` guards it. Do not reintroduce a compression suffix or a `FileHash`-derived URL.
  - **The narinfo is cached on disk, and that is what makes the artifact cache work at all.** A NAR request resolves its narinfo first; when that resolution went to the network, a fully populated cache answered 404 the instant upstream was unreachable — the exact case it exists for. Metadata now persists under `<stateDir>/narinfo/` with its **own** eviction budget, deliberately not shared with the NAR budget: evicting metadata to fit one more artifact trades a few hundred bytes for the ability to find anything at all.
  - **Local sources are read twice on purpose.** The cache and `nix-store --dump` hash the artifact in full and only then open the response, so a corrupt or tampered artifact yields a 404 and Nix never sees a byte. The upstream first-fetch cannot do this — Nix aborts a transfer delivering nothing for `stalled-download-timeout` (300s), so buffering a multi-gigabyte NAR would turn large paths from slow into impossible — and uses the one-chunk lookahead instead.
  - **Nothing is named until it is verified.** Cache writes land in `<stateDir>/tmp/` and are `rename`d into `nar/` only after the digest matches; `Slot`'s `Drop` removes an uncommitted temp, and `Cache::new` sweeps `tmp/` at startup because that cleanup is eventual. Both directories must stay on one filesystem — the atomicity of `rename(2)` is the guarantee.
  - `serveFromStore` uses **`nix-store --dump`, the old CLI, deliberately**: it serialises a directory and consults nothing else, so the daemon needs no Nix database access and never opens the nix-daemon socket — which is why `RestrictAddressFamilies` can stay `AF_INET AF_INET6`. It never asks whether a path is *valid* either; the output is hashed against the signed `NarHash`, so present-but-invalid debris fails and falls through.
  - **Content-addressed paths need no signature, and that has bitten a test here already.** `ValidPathInfo::checkSignatures` returns `maxSigs` immediately for a CA path without examining any signature — the anchor is the store path name, which `isContentAddressed` recomputes from the `CA:` field. So `nix-store --add` output cannot be used to test signature refusal (stripping its `Sig:` changes nothing), and for CA paths the adapter's own `NarHash` check adds nothing independent; Nix's CA re-derivation in `addToStore` is what catches a mismatch.
  - **There are TWO listeners and the separation is the design, not tidiness.** The substituter surface is loopback-only and will proxy anything its upstreams hold — exposing it would publish an open cache proxy for the whole of cache.nixos.org. The peer surface (`custom.p2pCache.peer`, default off, port 5112) binds a real interface and answers a deliberately smaller question: *do you already have this?* It never triggers an upstream fetch on a peer's behalf, serves nothing it has not verified, and has its own route set so a peer that finds the wrong port still cannot drive the proxying surface. Reach is per-interface via `peer.openFirewall`, empty by default — the same shape `services.demod-talk` uses.
  - **Peer addresses are restricted to private ranges in code**, not left to the firewall. RFC1918 / CGNAT-tailnet / link-local is exactly the set `strict-egress.nix` already allows statically, which is why a LAN swarm needs no egress change; accepting a routable peer would quietly step outside that. A public entry in `peers` is dropped with a loud log rather than being fatal, because an optional transport must not be able to take the substituter down.
  - **Peers supply metadata as well as bytes, and must.** A NAR cannot be verified without the signed `NarHash`, which lives in a narinfo, so without a peer narinfo leg the transport is useless offline. What comes back is upstream's narinfo verbatim — signature intact — and `LanTransport::narinfo` re-checks that it names the store path that was asked for. Nix still verifies the signature; the adapter is a courier, not an authority.
  - **A peer fetch is verified in full before anything is served**, unlike the upstream path, because peers are on a LAN and are the untrusted source that most deserves the stronger guarantee.
  - **Testing a peer transport is where vacuous tests come from.** NixOS test nodes share the *host's* `/nix/store`, so a "leecher" node can see artifacts it does not have in its database — with `serveFromStore` on, the peer transport is never exercised. And corrupting a well-behaved seeder's cache proves the *seeder* is honest: it verifies before serving and refuses first, so the leecher never sees bad bytes. Proving a leecher refuses a lying peer requires an actually hostile peer, which `.#p2p-two-node` ships as a `writeText` derivation.
  - **A peer can only serve metadata it has itself resolved, so it seeds what it FETCHED, not what it built.** The peer surface never goes upstream on a peer's behalf, so `GET /peer/v1/narinfo/<hp>` answers only from the on-disk narinfo cache; without `NarHash` the receiver has nothing to verify against. A locally-built path has no narinfo anywhere and therefore cannot be seeded at all — fixing that would make the seeder a signing authority for those paths, which is a much larger question than a transport. This is why `.#p2p-two-node` warms its seeder by running a real substitution rather than by fetching one narinfo.
  - **BitTorrent discovery is not BitTorrent's.** `disable_dht: true`, no trackers, no PEX — peers *and* infohashes both come from the stage-3 peer surface, because every address dialled has to come from the private-range peer list for this to work under `strict-egress` unchanged. `AddTorrentOptions { initial_peers, disable_trackers }` is what makes a tracker-less, DHT-less swarm expressible at all. It also adds nothing to the trust story: piece hashes come from a `.torrent` an untrusted peer handed us, so the completed file is still hashed against the signed `NarHash` before it gets a name.
  - **A transport method must never block, and getting that wrong has two distinct failure modes.** `Handle::block_on` from an async handler panics (`Cannot start a runtime from within a runtime`); from a `spawn_blocking` thread it never returns at all — no panic, no error, a healthy-looking daemon and a task sitting there forever. Both shipped and both were caught by `.#p2p-swarm`. `provide`/`remove` spawn onto the runtime and return; the trade is that `remove` has no ordering guarantee against eviction, which librqbit survives.
  - **`minArtifactSize` (default 4 MiB) is checked in `discover`, before any peer is contacted.** This closure's median NAR is 355 KiB and a swarm per NAR would be pathological; 4 MiB puts 16.4% of paths in swarms while covering 96.0% of the bytes. Checking it in `fetch` instead would cost a round trip on every small path.
  - **A host seeds at every point an artifact becomes a cache entry** — upstream fetch, `nix-store --dump`, peer fetch — and re-announces the whole cache at startup, because a restart otherwise silently stops seeding everything while the daemon still looks healthy.
  - The daemon's user is a **static system user, not `DynamicUser`**, because `strict-egress`'s `allow.uids` matches `meta skuid "<name>"` against passwd at ruleset-load time and cannot name a runtime-allocated uid.
- `modules/ArchibaldOS/` — the RT DSP guest OS, its own flake under `modules/ArchibaldOS/modules/`.

When changing one of these, build/iterate inside that sub-flake; the top-level flake consumes it as a pinned `path:` input.

`modules/hypr-controller/` is a different shape — not a sub-flake. `nixos-module.nix` + `hypr_bridge.py` declare `services.dcf-hypr-agent` (a DCF-Hypr bridge that relays Hyprland IPC + an `oligarchy-ctl` passthrough over UDP to the `android/` companion app, a plain Gradle/Kotlin project with no Nix build of its own). It's imported directly by `configuration.nix` next to `./modules/dcf-mesh-agent.nix`, off by default, and — like `dcf-mesh-agent` — is deliberately **not** part of the read-only MCP surface (`mcp_self_audit` fails the build if it ends up in `.mcp.json`). See `modules/hypr-controller/README.md`.

Its `spaGated` option pulls in `modules/security/dcf-spa-gate.nix` (`networking.firewall.spaGate`). **Do not "simplify" that by importing HydraMesh's own `spa/modules/dcf-spa.nix`** — upstream sets `networking.nftables.enable`, which switches the global firewall backend and fails eval against `demod-ip-blocker`'s ipset/iptables `extraCommands`. Like `strict-egress.nix`, the gate ships a self-contained `inet` table loaded by its own oneshot service so it coexists with the iptables firewall; its chain is `policy accept` (only the gated port is dropped) rather than upstream's whole-system `policy drop`. Only upstream's `dcf-spa-authorizer` *binary* is reused. `tests/default.nix -A dcf-spa-gate` guards all of this.

### `vm-manager/`

A sub-flake providing two NixOS modules — `quickemu-vm` and `dsp-vm` — plus per-VM definitions in `vm-manager/config/` (DSP, coding sandbox, Kali, OpenWRT). The DSP VM is the latency-critical RT guest (NETJACK, isolated CPU core via `isolcpus=0`).

### `home/`

Home Manager user environment for `asher`. `home/home.nix` is the entrypoint; it builds a feature/profile set (`defaultFeatures`, `profiles/`) that gates desktop pieces, and a theme/palette system in `home/themes/` (the `p`/`activeTheme` shorthand seen throughout). Desktop config is split across `home/apps/` (KDE/Qt/GTK theming), `home/hyprland/`, `home/waybar/`, `home/x11/`, `home/terminal/`, `home/shell/`. Many `home/apps/*` modules take a `theme`/palette argument rather than reading global config.

## Conventions

- **Unfree + broken allowed.** `pkgsConfig` sets `allowUnfree = true` and `allowBroken = true`; builds may pull proprietary firmware/drivers (NVIDIA, etc.).
- **Pin everything through the flake.** New external dependencies become flake inputs, not ad-hoc fetches — the project explicitly avoids unpinned sources.
- **Secrets** use `sops-nix`. `secrets/` is git-ignored except `secrets/.sops.yaml`. Never commit decrypted material, `*.age`, or `secrets/secrets.yaml`.
- **State version is `25.11`** on `nixos-25.11` (nixpkgs stable). Keep new modules consistent with that. `nixpkgs-unstable` is available via the `unstable` overlay for cherry-picks.
- **MCP servers are read-only + dry-run by construction.** The agent surface can never mutate the running system. Each aspect server has a per-aspect CLI allowlist (`modules/mcp-servers/crates/core/src/allowlist.rs`) enforced at runtime by `runner::run` — reach CLIs only through it, never via a bare `Command::new`. The `ports-sec` crate is the only one permitted to open sockets (loopback-only, feature-gated). `nix build .#mcp-self-audit` enforces the socket rule and checks `.mcp.json` for remote transports at the project level.
- `modules/demod-talk/` — DCF-Talk sub-flake: the pure-Lua DCF chat stack (certified text + Snake adapters, voice L3 with jitter/PLC/DTX, SuperPack + Reed-Solomon transport, StreamDB history). `services.demod-talk.enable`, **off by default**. Plaintext by design — DCF carries no encryption to stay clear of EAR/ITAR — so `interface` is mandatory with no default, the firewall opens on that interface only, and an assertion fails the build if it is not a WireGuard interface declared on this host (unless an over-the-air transport is chosen, where plaintext is lawful and expected). The package's `checkPhase` runs all six golden-vector certifications plus four smoke modes, so a failed certification is a failed build. Ships `dcf-talk`, `dcf-jam`, `dcf-certify`. See `modules/demod-talk/README.md`.
- **HydraMesh is a hard requirement of the distro,** not an optional feature: `modules/hydramesh.nix` (`custom.hydramesh.enable`) defaults to **true** and installs the `hydramesh` / `dcf` SDK CLIs plus the HydraModem toolbox. The ISO force-disables it. `services.dcf-mesh-agent` is a separate, read-write, UDP-bound Python endpoint that is deliberately NOT part of the MCP surface and must stay out of `.mcp.json`.
# Tiered Plugin Runtime — Design & Living Roadmap

> **Status:** LIVING DOCUMENT. Stage 1 is landed. Update the stage table and
> the changelog at the bottom as work proceeds. The design section above the
> line is the locked contract; the roadmap below the line is the work tracker.
>
> **Source:** `modules/oligarchy-plugins/` (self-contained sub-flake, consumed
> as `path:./modules/oligarchy-plugins`). Its own `README.md` is the upstream
> design writeup; this file is Oligarchy's integration record.

---

## 1. Purpose

An **imperative** plugin system on a declarative OS, and the foundation the FX
Bazaar is meant to sit on. One WIT ABI (`oligarchy:plugin@0.1.0`) across WASM,
native and Lua plugins; three sandbox tiers chosen per plugin from a capability
manifest; and per-instance W^X, so a plugin that genuinely needs a JIT can have
one without every other plugin on the machine inheriting the concession.

The problem it exists to solve: "sandbox everything" and "support JIT" are in
direct tension. `MemoryDenyWriteExecute`, SELinux `execmem` and kernel lockdown
all work by refusing to let a process turn writable bytes into executable ones —
which is exactly what a JIT does. Turn the mitigation on and LuaJIT, PCRE-JIT,
V8 and .NET break. Turn it off and you have conceded the category for the whole
box. The answer here is to decide **per plugin, declaratively, at the unit
level**, and to route the cases where the answer is genuinely "no" into a guest
kernel where it does not have to hold on the host.

## 2. The seam

| | Declarative (flake, reviewed, rolls back) | Imperative (mutable, no rebuild) |
|---|---|---|
| policy.json | ✔ | |
| `plugind` + closure | ✔ | |
| `oligarchy-plugin@.service` template | ✔ | |
| state directory layout (tmpfiles) | ✔ | |
| trusted public keys | ✔ | |
| which plugins exist | | ✔ |
| which are enabled | | ✔ |
| their config | | ✔ |

`custom.plugins.declaredPlugins` is the escape hatch for a first-party set you
want pinned in the closure; it goes through the *same* manifest schema and the
*same* `authorize()` path as an imperative install, so there is no second code
path and no second set of bugs.

## 3. The tiers

| | Tier 0 `wasm` | Tier 1 `native` / `lua` | Tier 2 `microvm` |
|---|---|---|---|
| memory safety | by construction | none | guest kernel boundary |
| unit `MemoryDenyWriteExecute` | **no** (host JITs) | from `jit` | yes (host side proxies only) |
| `PROT_EXEC` in guest | never needed | per manifest | irrelevant |
| realtime-safe | yes | yes | **no** |
| startup | sub-ms (pooling alloc) | ~ms | ~125 ms + guest init |
| use for | anything you didn't write | CLAP/LV2/Faust hot path | untrusted + self-JIT |

## 4. The W^X rule (locked)

W^X is enforced exactly where the plugin's own machine code shares plugind's
address space **and** its syscall access:

```
wasm    -> NOT enforced. The unit is the one running Cranelift; MDWE there
           breaks Tier 0 outright while hardening nothing, because a wasm guest
           cannot issue a syscall at all except through host functions we wrote.
microvm -> enforced. The host side is a vsock proxy that never JITs.
native  -> enforced unless the manifest declares jit = "self".
lua        This is the case the whole design exists to get right.
```

This rule is written **twice**, on purpose:

- `Manifest::wx_enforced()` in `host/src/manifest.rs` (runtime, imperative path)
- `wxEnforced` in `modules/plugins.nix` (build time, declared path)

**They are a deliberate mirror. Change one and you must change the other.**
`nix build .#plugins-wx-enforcement` boots a real kernel and asserts they
agree; `manifest::tests::wx_is_enforced_where_it_means_something` and
`sandbox::seccomp::tests::wasm_tier_is_never_wx_filtered` guard the Rust half.

## 5. Trust: caches, not users

**Nobody is added to `nix.settings.trusted-users`.** Per the Nix manual that is
equivalent to giving that user root, and it would defeat the entire model. The
FX Bazaar is instead a **signed binary cache** in `trusted-substituters` with
its key in `trusted-public-keys`, and every path is `nix store verify`'d before
it is registered. Installed paths get a GC root so `nix store gc` cannot delete
a plugin out from under a running rig.

If a change appears to require `trusted-users`, that is the signal that
something upstream of it is wrong — say so rather than adding the entry.

---

## 6. Staging

One stage per commit. Each stage's gate must be green before the next starts.

| Stage | Scope | Gate | Status |
|---|---|---|---|
| 1 | Tier 0 (`wasm`) only, no imperative install, workstation host only | `plugind doctor` reports a usable Landlock ABI; `nix build .#plugins-wx-enforcement` passes | **DONE** |
| 2 | Signed registry + imperative install | an unprivileged user can install a *signed* plugin and cannot install an unsigned one, with nobody in `trusted-users` | not started |
| 3 | Tier 1 (`native`/`lua`) on the workstation only | `jit=none` vs `jit=self` verified on real hardware, not just in the VM test | not started |
| 4 | Tier 2 (`microvm`) | microvm.nix restored as an input; no collision with `vm-manager/` | not started |

### Current wiring (stage 1)

- Input: `oligarchy-plugins.url = "path:./modules/oligarchy-plugins"`, with
  `inputs.nixpkgs.follows = "nixpkgs"`.
- Module: `oligarchy-plugins.nixosModules.plugins`, imported **only** by
  `nixosConfigurations.nixos` (the Framework 16 workstation). It is not in
  `commonModules`, so `nixos-fw13`, `nixos-intel`, `nixos-optimus` and the ISO
  are untouched and need no `mkForce` disable.
- Posture on that host — and the permanent posture for a stage rig or a shipped
  instrument:

  ```nix
  custom.plugins = {
    enable = true;
    allowedTiers = [ "wasm" ];
    allowSelfJit = false;
    requireSignature = true;
  };
  ```

  `allowedTiers = [ "wasm" ]` is not merely a runtime refusal: the module
  derives `custom.plugins.package` from it, so `libloading`, `mlua` and the
  vendored LuaJIT are compiled out and are not in the closure at all.

  `requireSignature = true` with no `trustedPublicKeys` means nothing can be
  registered. That is the intent for stage 1 — the runtime is present, the
  registry is shut — and it is why the module's signature assertion fires only
  on the incoherent case (a configured substituter whose signatures no key on
  this host can check) rather than on an empty configuration.

- Gates, exposed as `packages` rather than `checks`, matching the `malwareScan`
  / `mcp-self-audit` precedent (real gates, slow, run on demand):

  ```console
  nix build .#plugins-wx-enforcement    # the one that matters
  nix build .#plugins-policy-refusal    # policy refuses at install, not at load
  ```

### Kernel facts (verified, Framework 16 / `custom.kernel.variant = "zen"`)

- Landlock ABI **v8** on Linux 7.0.10-zen1, with `landlock` in
  `/sys/kernel/security/lsm`. Network confinement needs ABI ≥ 4 (Linux 6.7), so
  Tier 1's network policy will be enforced by Landlock and the netns fallback is
  not needed on this host.
- Every kernel variant the distro offers clears that bar: `zen`, `xanmod` and
  `latest` are all ≥ 6.7, and `lts` pins to 6.12 (ABI v6).
- `landlock.rs` targets ABI **v5** deliberately. Raising `TARGET_ABI` widens the
  set of access rights we *handle*, which on an older kernel means BestEffort
  drops more of the ruleset — it is a policy change, not a version bump.

### Known gaps, by the stage that will hit them

**Stage 2 (signed registry + imperative install)**

1. **No cache exists yet.** `DeMoD Nix store.md` describes `/etc/demod` as a
   shared asset directory for DeMoD projects; it is not a binary cache spec, and
   there is no substituter or `trusted-public-keys` entry anywhere in this repo
   today. Stage 2 has to stand one up and get its key.
2. **Determinate Nix owns `nix.conf`.** The `determinate` module is in
   `commonModules`; confirm `nix.settings.trusted-substituters` /
   `trusted-public-keys` actually reach the running daemon rather than being
   generated into a file `determinate-nixd` ignores.
3. **There is no unprivileged install path.** `plugind install` writes the
   registry directly into `${stateDir}`, which is `0750 oligarchy:oligarchy`.
   The control socket that would let an unprivileged user ask the daemon to do
   it is explicitly a stub in `main.rs` ("The control socket handler is omitted
   here"). Stage 2's acceptance criterion cannot be met until it exists.
4. **Per-plugin state ownership.** `install()` creates `state/<id>` and
   `config/<id>` as the calling user. Installed by root, they are root-owned,
   and the plugin instance — which runs as `oligarchy` — cannot write its own
   state. Needs an explicit chown or creation via the daemon.
5. **The GC roots are not GC roots.** `install()` symlinks
   `${stateDir}/gcroots/<id>` at the store path, but a symlink is only a root
   if Nix knows about it — it has to be registered, e.g. via `nix-store
   --add-root` or a corresponding entry under `/nix/var/nix/gcroots/auto/`. As
   written, `nix store gc` can still delete a plugin out from under a running
   rig, which is the exact thing the code says it prevents.
6. **`nix` invoked from the supervisor unit.** `ProtectHome = true` masks
   `/root`, so `nix build` / `nix store verify` called from `plugind daemon`
   (rather than from a root shell) may not find a usable `HOME`. Untested,
   because stage 1 never reaches those calls.

7. **The plugin substituter is outside the egress allowlist.**
   `networking.firewall.strictEgress` is on (`configuration.nix`), and it
   already derives allowed domains from other modules' config via
   `autoDetectDomains` (fwupd, docker, acme). Nothing does that for
   `custom.plugins.substituters`, so the first host to point at a plugin cache
   gets a firewall-blocked `plugind install` with no build-time signal.
8. **Design question worth settling before writing the control socket:** the
   supervisor currently holds two unrelated privilege domains — writing
   drop-ins + `daemon-reload` (root, no user input) and `nix build` / registry
   mutation (should be unprivileged, user-driven). Splitting them would make
   the unprivileged-install criterion reachable. One shape: expose
   `plugind generate-dropins` and symlink it into `system-generators`, so
   "drop-ins are regenerated from the registry, never outliving it" becomes a
   systemd invariant instead of a reconcile loop, and the daemon drops back to
   `User = oligarchy` needing only `daemon-reload` + `start`, which *is*
   polkit-expressible.
9. **The signature assertion checks a proxy.** It asserts over
   `custom.plugins.{substituters,trustedPublicKeys}`, but `verify_signature`
   shells out to `nix store verify`, which reads
   `config.nix.settings.trusted-public-keys` system-wide. Another module adding
   a key or a substituter is invisible to it in both directions. Assert over
   the sets the verifier actually reads — or, if Determinate makes that
   unresolvable, demote it to a warning, since the runtime already refuses at
   install time.

**Stage 3 (tier 1)**

5. `security.unprivilegedUsernsClone` must be true; the module already sets it
   with `mkDefault` when `native`/`lua` is in `allowedTiers`, and the assertion
   catches the case where something else has forced it off.
6. The `jit=none` vs `jit=self` distinction has been verified only in unit tests
   and (for unit generation) in the VM test. It still needs a real-hardware
   check that a `jit=none` plugin actually gets EPERM on `mprotect(PROT_EXEC)` —
   `plugind`'s `#[cfg(debug_assertions)]` self-test forks and attempts exactly
   that.
7. `mlua` is pinned with the `vendored` feature, so it builds its own LuaJIT and
   ignores the `LUA_LIB`/`LUA_INC` the package sets. Decide deliberately which
   one Tier 1 should ship.

**Before the ABI is public (any stage)**

- `wasm.rs`'s `call_process` returns an owned `Vec<f32>` that is then copied
  into the output buffer: one allocation and two copies per audio block, on the
  callback that has to meet a deadline. That is imposed by the WIT signature
  (`list<f32>` return), so it is fixable only at the ABI level — before
  third-party plugins pin `oligarchy:plugin@0.1.0`, not after.
- The wasmtime pooling allocator is configured for 64 component instances and
  64 memories at 256 MiB, but the unit model is one `plugind run %i` process
  per plugin, so the pool is per-plugin and reserves on the order of 16 GiB of
  address space per instance. Virtual, not resident, so it does not fight
  `MemoryMax` — but it should match the actual unit topology.

**Stage 4 (tier 2)**

8. microvm.nix is **not** an input of the sub-flake. See the tier 2 note in
   `modules/oligarchy-plugins/flake.nix` for exactly what to restore. The
   config block is already written and gated on `options ? microvm`, so it
   costs a host that does not use it neither an option collision nor a flake
   input.
9. `vm-manager/` has no microvm.nix dependency today (its four guests are
   quickemu/QEMU), so there is no option collision to resolve — but the two
   will be managing VMs on the same host and that interaction is unexercised.
10. `vsock.cid = 3` is hardcoded for every guest, which cannot be right for more
    than one microvm plugin at a time.

---

## 7. Changelog

- **Stage 1** — vendored `oligarchy-plugins` as a sub-flake; generated
  `host/Cargo.lock`; fixed the wasmtime 43 / landlock 0.4 API drift; fixed the
  NixOS-specific defects in the module (drop-in mechanism, supervisor
  privileges); wired tier 0 onto `nixosConfigurations.nixos`.

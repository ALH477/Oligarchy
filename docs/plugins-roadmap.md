# Tiered Plugin Runtime — Design & Living Roadmap

> **Status:** LIVING DOCUMENT. Stages 1 and 2 are landed. Update the stage table and
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
| 2 | Signed registry + imperative install | an unprivileged user can install a *signed* plugin and cannot install an unsigned one, with nobody in `trusted-users` | **DONE** |
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

### Current wiring (stage 2)

The seam that makes an unprivileged install possible without anyone being
trusted to Nix is a **control socket**, not a loosened registry.

```
   alice (in oligarchy-plugins)          plugind daemon (root)
   plugind install <path>
     │  registry not writable            /run/oligarchy/plugins/control.sock
     └──────── one line of JSON ────────►  0660 root:oligarchy-plugins
                                           │
                                           ├─ nix store verify --sigs-needed 1
                                           ├─ Policy::authorize(manifest)
                                           ├─ nix-store --add-root
                                           └─ write the registry
```

Five properties, in the order they matter:

0. **A signature has to actually be there.** `nix store verify --sigs-needed 1`
   is *not* sufficient on its own and this nearly shipped believing it was.
   Nix short-circuits verification for content-addressed paths — upstream sets
   the signature count to max before consulting a key — and `nix store
   add-path` requires no privilege at all. So any installer could author
   arbitrary content, add it to the store, and have it register as
   `signature_verified: true` on a `requireSignature = true` host. Confirmed
   empirically, not theorised. `verify_signature` now requires **both** that a
   signature is present naming a key policy pinned (from `path-info`) and that
   `nix store verify` accepts it: the first defeats the content-addressed
   short-circuit, the second defeats a forged signature bearing a trusted name.

   The first version of `checks.signed-install` passed while this hole was
   open, because both its negative fixtures were `runCommand` outputs and
   therefore *input*-addressed — they failed verification for the wrong reason.
   The test now builds a content-addressed path with `nix store add-path`, and
   asserts it is content-addressed with no signatures before asserting the
   install is refused, so it cannot quietly stop testing anything.
1. **The wire format has no `allow_unsigned` field.** Not "the server ignores
   it" — `Request::Install` cannot encode it, and `deny_unknown_fields` turns an
   attempt to smuggle it into a parse error. A check can be dropped in a
   refactor; an absent field cannot.
2. **Policy outranks the CLI.** `--allow-unsigned` exists for development, but
   on a `requireSignature = true` host it is *refused*, not honoured — otherwise
   the declarative half of the design would be advisory and the flag a
   rebuild-free way around it. `Policy::authorize_signature` in
   `policy.rs` is that rule — it lives next to `authorize` because it is the
   same kind of statement, the machine owner's answer rather than the caller's
   request, and being a pure function over the Policy makes the whole truth
   table testable without a store, a daemon or a key.
3. **The socket does not hand root what root does not need.** The supervisor
   runs as root for exactly two operations — writing a drop-in under
   `/run/systemd/system` and `daemon-reload` — and `install` is neither.
   `source` is caller-supplied and may be a flake ref, so evaluating it in a
   root process would be root code execution however narrow the request format
   is. `nix_cmd()` in `registry.rs` is the single place a Nix subprocess is
   built, and it drops `nix build` / `nix store verify` / `nix-store --add-root`
   to the account that owns the state directory. The nix-daemon does the actual
   building either way, so nothing is lost.

   This is the answer to the design question the stage-1 review raised (split
   the supervisor's two privilege domains, possibly via a systemd generator).
   The socket stays — polkit can express "may call daemon-reload" but cannot
   express "may install *only* a signed, policy-authorised plugin", and that
   predicate is the whole design. What the generator idea was really about was
   the root surface reachable from user input, and dropping privileges inside
   the handler closes that without moving the mechanism. The generator remains
   the better answer if the drop-in write itself ever needs to be reachable
   from a request; today it is not.
4. **`installGroup` is not `group`.** `custom.plugins.group` is what the runtime
   runs as and its members can read every plugin's state directory.
   `custom.plugins.installGroup` conveys exactly one power: may ask for a
   signature-checked install. `custom.plugins.installers` is the option that
   exists so that `nix.settings.trusted-users` does not have to be.

Also landed with stage 2:

- `substituters` **and** `trusted-substituters` both get the configured caches.
  They are not redundant: the first is what Nix consults by default (without it
  `plugind install` would never fetch from the plugin cache), the second is the
  list an untrusted user may select explicitly. Neither grants anything alone —
  a path is accepted only if signed by a key in `trusted-public-keys`.
- **The key set is pinned, not inherited.** `nix.settings.trusted-public-keys`
  legitimately carries cache.nixos.org and, on a Determinate host, nine
  flakehub keys — and a plugin signed by cache.nixos.org is not a plugin this
  host approved. `policy.json` now carries `trusted_public_keys`, and plugind
  pins it on the verifying subprocess through `NIX_CONFIG` rather than
  `--option` (a restricted setting passed on the command line by an untrusted
  client is ignored). That also closes a second hole: `NIX_CONFIG` outranks
  every config file, so a `nix.conf` planted under an attacker-writable `HOME`
  cannot widen the key set back.
- **The registry directory is root-owned.** It is the *input* to the drop-in
  generator that root runs, so a plugin user who could write it could inject
  `User=root` into its own unit and have the next reconcile apply it. Instances
  still need to read it, hence `0750 root:oligarchy`. Belt and braces, every
  manifest that comes back out of `registry.json` is re-validated, because a
  generator whose safety rests on one directory mode is a generator waiting for
  that mode to change.
- **One lock across every registry mutation, including the `systemctl start`.**
  Without it `enable` (write drop-in → reload → start) and a concurrent
  `disable` (delete drop-in → reload) interleave so the instance starts under
  the *template alone* — and the template deliberately omits
  `MemoryDenyWriteExecute`, `DevicePolicy`, `MemoryMax` and `PrivateNetwork`,
  with `DevicePolicy` defaulting to unrestricted. That is the headline
  invariant defeated by two legitimate requests. Note the shape of the bug the
  fix introduced and then removed: a `Store` holds the lock for its lifetime,
  so the daemon's own long-lived `Store` deadlocked every request. It is now
  scoped, and `lock_registry` logs before it blocks.
- **`chown` no longer follows symlinks.** `create_dir_all` returns `Ok` when the
  target is already a symlink to a directory and `chown(2)` follows symlinks —
  so the previous path-based chown was an arbitrary-chown primitive for whoever
  owned the state directory's contents. Point `state/<id>` at `/etc`, wait for a
  reinstall, and root hands `/etc` to the plugin user. Now `O_NOFOLLOW |
  O_DIRECTORY` and `fchown`.
- **The supervisor has its own runtime directory.** systemd chowns a
  `RuntimeDirectory` to the owning unit's `User` and deletes it when that unit
  stops, so a control socket living in the *instances'* directory could be
  unlinked by disabling any plugin — one legitimate request to break the
  install path for everyone — and, once an instance had run, would sit in a
  directory the unprivileged plugin user owned and could rebind.
- **Bounds on a root process reachable from an unprivileged socket.**
  `read_line` is capped at 64 KiB (it was unbounded allocation in a root
  process), and the unit gets `MemoryMax`, `TasksMax` and `UMask = 0027`.
- **`forbidden_paths` compares path components.** `//home/x` and `/./home/x` are
  the same path to the kernel but do not byte-prefix-match `/home`, while
  `/homework` does. Both directions were wrong.
- **`list` returns the registry, not a table.** `control::Reply` is
  `Text | Entries`: messages stay prose (an install done for you should read
  like one you did yourself), but `list` hands back `Vec<Entry>` and the client
  formats it. The socket is meant to be the FX Bazaar UI's API as much as the
  CLI's, and a UI cannot consume 28-column ASCII.
- **The key set is pinned, not inherited.** `nix.settings.trusted-public-keys`
  legitimately carries cache.nixos.org and, on a Determinate host, nine
  flakehub keys — and a plugin signed by cache.nixos.org is not a plugin this
  host approved. `policy.json` now carries `trusted_public_keys`, and plugind
  pins it on the verifying subprocess through `NIX_CONFIG` rather than
  `--option` (a restricted setting passed on the command line by an untrusted
  client is ignored). That also closes a second hole: `NIX_CONFIG` outranks
  every config file, so a `nix.conf` planted under an attacker-writable `HOME`
  cannot widen the key set back.
- **The registry directory is root-owned.** It is the *input* to the drop-in
  generator that root runs, so a plugin user who could write it could inject
  `User=root` into its own unit and have the next reconcile apply it. Instances
  still need to read it, hence `0750 root:oligarchy`. Belt and braces, every
  manifest that comes back out of `registry.json` is re-validated, because a
  generator whose safety rests on one directory mode is a generator waiting for
  that mode to change.
- **One lock across every registry mutation, including the `systemctl start`.**
  Without it `enable` (write drop-in → reload → start) and a concurrent
  `disable` (delete drop-in → reload) interleave so the instance starts under
  the *template alone* — and the template deliberately omits
  `MemoryDenyWriteExecute`, `DevicePolicy`, `MemoryMax` and `PrivateNetwork`,
  with `DevicePolicy` defaulting to unrestricted. That is the headline
  invariant defeated by two legitimate requests. Note the shape of the bug the
  fix introduced and then removed: a `Store` holds the lock for its lifetime,
  so the daemon's own long-lived `Store` deadlocked every request. It is now
  scoped, and `lock_registry` logs before it blocks.
- **`chown` no longer follows symlinks.** `create_dir_all` returns `Ok` when the
  target is already a symlink to a directory and `chown(2)` follows symlinks —
  so the previous path-based chown was an arbitrary-chown primitive for whoever
  owned the state directory's contents. Point `state/<id>` at `/etc`, wait for a
  reinstall, and root hands `/etc` to the plugin user. Now `O_NOFOLLOW |
  O_DIRECTORY` and `fchown`.
- **The supervisor has its own runtime directory.** systemd chowns a
  `RuntimeDirectory` to the owning unit's `User` and deletes it when that unit
  stops, so a control socket living in the *instances'* directory could be
  unlinked by disabling any plugin — one legitimate request to break the
  install path for everyone — and, once an instance had run, would sit in a
  directory the unprivileged plugin user owned and could rebind.
- **Bounds on a root process reachable from an unprivileged socket.**
  `read_line` is capped at 64 KiB (it was unbounded allocation in a root
  process), and the unit gets `MemoryMax`, `TasksMax` and `UMask = 0027`.
- **`forbidden_paths` compares path components.** `//home/x` and `/./home/x` are
  the same path to the kernel but do not byte-prefix-match `/home`, while
  `/homework` does. Both directions were wrong.
- **`list` returns the registry, not a table.** `control::Reply` is
  `Text | Entries`: messages stay prose (an install done for you should read
  like one you did yourself), but `list` hands back `Vec<Entry>` and the client
  formats it. The socket is meant to be the FX Bazaar UI's API as much as the
  CLI's, and a UI cannot consume 28-column ASCII.
- **Real GC roots.** `install` now goes through `nix-store --add-root`. A bare
  symlink into the store is not a root; only a path registered under
  `/nix/var/nix/gcroots` is, so the previous version's comment was aspirational
  and `nix store gc` really could delete a plugin out from under a running rig.
  The test asks Nix (`nix-store -q --roots`), not `ls`.
- **Per-plugin state ownership.** `state/<id>` and `config/<id>` inherit the
  owner of the tree they live in, so a directory the root supervisor created is
  writable by the unprivileged plugin instance that has to use it.
- **plugind asks for the Nix CLI it uses.** `nix build` and `nix store verify`
  are new-CLI subcommands, so on a host that has not enabled
  `experimental-features = nix-command` every install failed — including the
  signature check, which is the one thing that must never fail to *run*. Both
  invocations now pass `--extra-experimental-features` themselves. Neither
  feature grants privilege; they gate the interface, not the trust model.
- **`networking.firewall.strictEgress.autoDetect.nixSubstituters`** (new,
  default true) allows the hostname of every cache in `nix.settings`. Derived
  from `nix.settings` rather than from `custom.plugins.substituters` so it works
  for any module that adds a cache, and so strict-egress does not reference an
  option that may not be declared on a given host.
- A **warning** fires if `nix.settings.trusted-users` names anyone but root
  while the plugin runtime is enabled: signature checking is decorative for
  such an account, and saying so is more useful than silently pretending
  otherwise.

Posture on the workstation is stage 1's plus `installers = [ <primary user> ]`.
`substituters` and `trustedPublicKeys` stay **empty** — see gap 1 below; until a
cache exists the only installable artifact is a locally signed store path, which
is exactly as verified as a fetched one.

Gate: `nix build .#plugins-signed-install`.

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

**Stage 2 leftovers — the only thing still open**

1. **No cache exists yet.** `DeMoD Nix store.md` describes `/etc/demod` as a
   shared asset directory for DeMoD projects; it is not a binary-cache spec, and
   there was no substituter or `trusted-public-keys` entry anywhere in this repo
   before stage 2. The *mechanism* is now complete and proven — a signed path
   installs, an unsigned one does not — but the FX Bazaar still needs an actual
   cache. Self-hosted, per the project's budget posture. The operational steps:

   ```console
   # once, on a machine that is not the one serving:
   nix-store --generate-binary-cache-key cache.demod.ltd-1 \
       /etc/demod/keys/cache.sec /etc/demod/keys/cache.pub
   # then, per artifact:
   nix store sign --key-file /etc/demod/keys/cache.sec <path>
   nix copy --to 'file:///srv/demod-cache' <path>   # or s3://, or nix-serve
   ```

   The public half goes in `custom.plugins.trustedPublicKeys`, the URL in
   `custom.plugins.substituters`, and `strictEgress.autoDetect.nixSubstituters`
   picks the hostname up on its own. **Keep the secret half off every machine
   that runs plugins** — signing is an authoring step, not a runtime one.

2. **Determinate: resolved, no action needed.** `/etc/nix/nix.conf` carries
   `!include nix.custom.conf`, and `nix config show` on the running host
   confirms the NixOS-generated `trusted-public-keys` / `substituters` /
   `trusted-users = root` all reach the daemon. `nix.settings` works.

3. **Worth knowing:** `trusted-public-keys` is a *restricted* Nix setting — an
   untrusted user cannot override it on the command line ("ignoring the
   client-specified setting … because it is a restricted setting"). That is a
   load-bearing property of this design, not an inconvenience: it is why an
   installer cannot bring their own key.

**Stage 3 (tier 1)**

4. `security.unprivilegedUsernsClone` must be true; the module already sets it
   with `mkDefault` when `native`/`lua` is in `allowedTiers`, and the assertion
   catches the case where something else has forced it off.
5. The `jit=none` vs `jit=self` distinction has been verified only in unit tests
   and (for unit generation) in the VM test. It still needs a real-hardware
   check that a `jit=none` plugin actually gets EPERM on `mprotect(PROT_EXEC)` —
   `plugind`'s `#[cfg(debug_assertions)]` self-test forks and attempts exactly
   that.
6. `mlua` is pinned with the `vendored` feature, so it builds its own LuaJIT and
   ignores the `LUA_LIB`/`LUA_INC` the package sets. Decide deliberately which
   one tier 1 should ship.
7. The control socket currently reaches only wasm-installable plugins in
   practice, because that is all `allowedTiers` permits on the workstation. When
   tier 1 opens, an installer can request a `native` plugin — signed, but native
   code all the same. Decide whether `installGroup` should be allowed to install
   at every permitted tier or only at tier 0; `minTrust` is the existing dial,
   and it is currently `untrusted`.

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

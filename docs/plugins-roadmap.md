# Tiered Plugin Runtime — Design & Living Roadmap

> **Status:** LIVING DOCUMENT. Stages 1-4 are landed and all five gates pass.
> Stage 3's W^X claim was FALSE until stage 4 and the correction is recorded
> under §4.1 — read that first. Update the stage table and
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

### 4.1 The W^X claim was false, and how

Stage 3 asserted that `jit = "none"` means no writable-executable memory, and
shipped a real-hardware selftest plus an end-to-end probe that both said so. An
adversarial review disproved it by running code on this kernel. **Three
independent routes worked, one of them under a real
`MemoryDenyWriteExecute=yes` unit:**

| route | why the filter missed it |
|---|---|
| anonymous `PROT_EXEC` written via `ptrace(POKEDATA)` | `ptrace` writes with `FOLL_FORCE`, so page protection is not consulted — and the mmap rule required `PROT_WRITE|PROT_EXEC` *together*, so an exec-only mapping never tripped it |
| the same, written via `userfaultfd` + `UFFDIO_COPY` | ditto; `UFFD_USER_MODE_ONLY` needs no privilege |
| plain-file dual mapping in `$STATE` | `seccomp.rs` asserted jit=none "requires that every writable mount is noexec" and **nothing ever implemented it** |

What made it invisible is the more useful lesson: both probes tested only the
two routes the filter already covered, so both reported "denied" while three
others were open. **A probe that only tests what you already blocked tells you
nothing.** `plugind selftest` and `wx-probe.c` now probe six routes and report
each by name; the tier 1 gate asserts all six.

The fixes, in the order they matter:

- **Deny any anonymous `PROT_EXEC` mapping**, write bit or not. This closes the
  class at its root rather than chasing writers one at a time, and costs
  `dlopen` nothing — shared objects are file-backed, so `MAP_ANONYMOUS` is not
  set. A plugin that genuinely needs anonymous executable memory is one
  declaring `jit = "self"`, and this filter is not installed for those.
- **Deny `ptrace` and `userfaultfd`** when W^X is enforced. Belt and braces: the
  target for a *private file-backed* executable mapping, which `dlopen`
  legitimately creates, is still copy-on-write and still pokeable.
  `process_vm_writev` is deliberately *not* denied — it does not pass
  `FOLL_FORCE`, verified rather than assumed.
- **`NoExecPaths=/ ${stateDir}` plus `ExecPaths=/nix/store`**, in both drop-in
  mirrors. Verified on this kernel that both the `MAP_SHARED` and `MAP_PRIVATE`
  exec-mappings of a writable file are then refused, and that noexec survives
  bwrap re-binding the directory — an unprivileged bind cannot relax mount
  flags. The state directory has to be named **explicitly**: with only `/`
  listed, `StateDirectory=`'s own bind mount came back executable, and the
  six-route probe is what caught it.

Result, from inside the sandbox, on a booted kernel:

```
WXPROBE exec=denied  memfd=denied  anon=denied  dualmap=denied  ptrace=denied  uffd=denied   (jit=none)
WXPROBE exec=allowed memfd=allowed anon=allowed dualmap=allowed ptrace=allowed uffd=allowed  (jit=self)
```

Still open from the same review, and not yet fixed:

1. **`RestrictNamespaces = "user mnt pid ipc uts cgroup net"` lets a plugin
   regain every capability.** `unshare(CLONE_NEWUSER|CLONE_NEWNET)` from an
   empty capability set restores a full set inside the new namespace, and with
   `AF_NETLINK` allowed that reaches the `nf_tables` parser — the surface
   CVE-2022-32250 and CVE-2023-32233 live on. Verified. Landlock still denies
   `mount` and `pivot_root` with all caps regained, so the classic userns
   filesystem escape is closed; this is about kernel LPE surface. The fix is
   cheap and has an obvious home: bwrap needs the namespaces only during setup,
   so the *shim* can add `unshare`/`setns`/`clone(CLONE_NEWUSER)` to its own
   filter after the namespaces exist.
2. **The cgroup caps are opt-in by the plugin.** Both mirrors emit `MemoryMax=`
   / `CPUQuota=` only when the *manifest* asks. `custom.plugins.limits.*` is a
   ceiling on what a manifest may request, never a default that gets applied —
   so a manifest that omits both runs with no memory cap and no CPU quota, and
   `RestrictRealtime` is unset. On an audio box the failure mode is a
   `SCHED_FIFO` spin loop. The compensating control quoted for `jit=self`
   ("hard cgroup caps") is absent exactly when the author declines to ask.
3. **`caps.devices` is dead.** bwrap `--dev-bind-try`s each device and the
   drop-in emits `DeviceAllow=`, but `sandbox::prepare` never adds `/dev` to the
   Landlock ruleset — so `open("/dev/snd/seq")` is `EACCES`. Any real DSP plugin
   that touches an ALSA node or `/dev/urandom` fails. `wx-probe.c` opens no
   devices, so no gate catches it. Same for `caps.fs_read_write` beyond
   `$STATE`: those paths are never bind-mounted, so the Landlock build fails
   with ENOENT and the unit will not start (fail-closed, but "whatever its
   manifest named" is currently only true for read-only paths).
4. **Landlock cannot gate unix-socket `connect()`**, so for sockets bwrap is the
   only layer — and `forbidden_paths` does not list `/nix/var`, so
   `fs_read = ["/nix/var/nix/daemon-socket"]` passes policy and hands the plugin
   the nix-daemon. `/proc`, `/sys`, `/etc` and `/run/dbus` are equally unlisted.
   Add them, and treat `fs_read` of a socket as read-write.
5. **`network = true` with an empty `tcp_connect` denies all TCP** while
   `plugind explain` prints "ALL TCP". Fail-closed, but the tool states the
   opposite of what the kernel will do.
6. **`NotifyAccess=all` lets a plugin send `EXTEND_TIMEOUT_USEC=`** repeatedly
   during stop, hanging `systemctl stop`, `nixos-rebuild switch` and shutdown
   indefinitely. `STOPPING=1` and `RESTART_RESET=1` are reachable too. The
   earlier note that this is "self-harm at worst" is too generous.
7. **The Lua tier's one diagnostic is inverted.** `jit.status()` reports the
   *setting*, not the capability, so a correctly-filtered `jit=none` Lua plugin
   logs "the W^X filter did not take" every time — training an operator to
   ignore the exact message meant to catch a real failure.

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
| 3 | Tier 1 (`native`/`lua`) on the workstation only | `jit=none` vs `jit=self` verified on real hardware, not just in the VM test | **DONE** |
| 4 | Tier 2 (`microvm`) | microvm.nix restored as an input; no collision with `vm-manager/` | **DONE** |

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

### Current wiring (stage 3)

Tier 1 runs a `dlopen`'d `.so` (or LuaJIT) under bwrap + Landlock + seccomp, as
the unprivileged `oligarchy` user, in its own systemd instance. Posture on the
workstation — and **only** the workstation:

```nix
allowedTiers = [ "wasm" "native" "lua" ];
allowSelfJit = true;         # emits a build warning; that is the point
minTrust     = "trusted";    # tightened now that native code can load
```

A stage rig or a shipped instrument keeps `[ "wasm" ]` and
`allowSelfJit = false`. There it is running plugins somebody else wrote.

**The gate, met on real hardware.** `plugind selftest` is a release-build verb
that builds the filter for a synthetic manifest at each `jit` setting, installs
it in a forked child, and has that child attempt exactly what the filter is
supposed to stop. On this Framework 16 (Linux 7.0.10-zen1, Landlock ABI v8):

```
  native jit=none  wx_enforced=true  mprotect(PROT_EXEC)=DENIED   memfd_create=DENIED   ok
  native jit=self  wx_enforced=false mprotect(PROT_EXEC)=allowed  memfd_create=allowed  ok
  wasm   jit=host  wx_enforced=false mprotect(PROT_EXEC)=allowed  memfd_create=allowed  ok
```

It is a release verb on purpose. A seccomp filter that silently failed to
install is the worst outcome in this design, and it is invisible from inside the
process that installed it — "the unit tests passed" does not detect it.

**And end to end, in `nix build .#plugins-tier1-runtime`.** Everything else that
touches W^X is indirect: unit tests prove the right BPF was assembled,
`wx-enforcement` proves the right `MemoryDenyWriteExecute` reached systemd,
`selftest` proves the kernel honours the filter in a child of plugind. None
prove what actually matters — that a plugin's own machine code, `dlopen`'d
inside bwrap after Landlock and seccomp are applied, gets the answer its
manifest declared. So `tests/wx-probe.c` is a real Tier 1 plugin whose `init()`
asks the kernel from exactly there and reports through the host log callback:

```
landlock fully enforced          plugin=wxnone
WXPROBE exec=denied  memfd=denied   plugin=wxnone
WXPROBE exec=allowed memfd=allowed  plugin=wxself
```

That one fixture exercises the whole tier at once: namespaces, the Landlock
ruleset, the seccomp filter, `dlopen`, the C vtable, the host-services struct,
the drop-in, and the journal.

**Tier 1 had never run, and nothing about it worked.** Seven separate blockers,
each of which stopped it dead:

1. `--ro-bind $RUNTIME/abi /abi` — a directory nothing creates, so bwrap failed
   on its first argument. It was vestigial; the C header is a compile-time
   artifact for plugin authors, not a runtime path.
2. State and config were remapped to `/state` and `/config`, but the shim builds
   its Landlock ruleset and expands `$STATE` from the *host* paths — so every
   `PathFd::new` would have hit ENOENT. Now bound at their real paths, so the
   manifest, the rules, the mounts and anything a plugin logs all agree.
3. The shim opened the registry, which is root-owned and deliberately not in the
   sandbox. It now gets `--store-path` on argv and reads the manifest from the
   artifact — which is also the right answer for confinement: a plugin has no
   business reading the list of every other plugin on the machine.
4. `policy.json` was not bound, so `Policy::load` fell back to the hardened
   defaults — tier 0 only — and every tier 1 plugin was refused by its own host.
5. `RestrictNamespaces = "user"` with the comment "bwrap needs userns and
   nothing else". It does not: bwrap creates user, mount, pid, ipc, uts, cgroup
   and net namespaces in **one** `clone()`, so denying any of them fails the
   whole call — and bwrap then reports "no permissions to creating new namespace
   … enable kernel.unprivileged_userns_clone", sending you after a sysctl that
   was never the problem.
6. `RestrictAddressFamilies=AF_UNIX` blocked the `NETLINK_ROUTE` socket bwrap
   uses to bring up loopback in the netns it just made. AF_NETLINK is now
   allowed for the bwrap tiers only; the namespace is empty and the process
   holds no capabilities, so there is nothing in there to configure but `lo`.
7. `ProtectKernelTunables=yes` locks a submount under `/proc`, and the kernel
   refuses `mount("proc")` in a user namespace when it cannot see an
   unobstructed `/proc`. Off for the bwrap tiers, where a fresh procfs, zero
   capabilities and a Landlock ruleset that does not name `/proc` replace it.

Then two that let it start but not *work*:

- `Type=notify` with `NotifyAccess=main` (the default) discards the shim's
  readiness notification, because MainPID is bwrap and the process that becomes
  ready is the child it forked. The unit sat for five minutes hitting
  `TimeoutStartSec` while a correctly confined plugin logged "ready" in the
  journal. `NotifyAccess=all` for the bwrap tiers; `exec` is not narrower enough
  to help. The notify socket also has to be in the Landlock ruleset and bound
  writable, because the shim reports ready *after* the ruleset is in force.
- `StartLimitBurst`/`StartLimitIntervalSec` were in `serviceConfig`, i.e.
  `[Service]`, where systemd ignores them — it said so on every start. The
  crashloop limit did not exist. They belong in `[Unit]`.

Two smaller corrections found on the way:

- `FsPolicy::baseline` added the artifact's own store path a *second* time with
  `EXECUTE` stripped. `dlopen` needs EXECUTE, and a narrower rule on the very
  directory the `.so` is loaded from is the last place to be relying on
  Landlock's rule-precedence semantics. `/nix/store` read+exec already covers it.
- A Landlock rule carrying directory rights on a non-directory (the notify
  socket) is *reported as degradation*: BestEffort strips them and the whole
  ruleset comes back `PartiallyEnforced`, so every tier 1 start logged "kernel
  is older than the policy" — a specific and false claim. Narrowed with
  `AccessFs::from_file`; it now reports `landlock fully enforced`.

**Two deliberate decisions.**

- **`mlua` no longer uses `vendored`.** That feature builds mlua's own bundled
  LuaJIT and ignores the `LUA_LIB`/`LUA_INC` the derivation sets — the opposite
  of what a distro wants. LuaJIT is now nixpkgs' LuaJIT: it carries the
  hardening flags, appears in the closure where the malware scan can see it, and
  gets patched when nixpkgs patches it rather than when someone remembers to
  bump a transitive crate.
- **The control socket cannot install a `jit=self` plugin.** `Authority` replaced
  the `allow_unsigned: bool` threaded through `install`: one type carrying both
  concessions only a registry-writer may request. "Which signed plugins may run"
  and "which signed plugins may hold W+X pages" are different decisions, and a
  signature says who wrote something, not that the operator wants it JITing.
  Bundling them means the *next* concession is added in one place rather than as
  a third bool some call site forgets.

### Current wiring (stage 4)

**What the plan asked for is done.** microvm.nix is an input of the sub-flake,
`nixosModules.default` (plugins + microvm host) is restored, and the workstation
imports it with `allowedTiers` gaining `"microvm"` and
`custom.plugins.microvm.enable = true`.

**No collision with `vm-manager/`.** microvm.nix's host module writes
`users.users.microvm`, `systemd.targets.microvms`,
`systemd.tmpfiles.settings."10-microvm"`, `boot.kernelModules += [ "tap"
"vhost_net" ]`, a `security.pam.loginLimits` entry and `/var/lib/microvms`.
vm-manager writes `custom.vm.{quickemu,dsp}`, `systemd.services.{quickemu-vm,
dsp-jack-bridge,dsp-netjack-bridge}` and `users.users.{asher,dsp}`. Nothing
overlaps; the two list-valued options merge. Both want `/dev/kvm`, which is fine.
`microvm.autostart` is deliberately left empty — a plugin's guest is started by
its own unit's dependency, so autostarting would give one guest two owners.

**But tier 2 was never implemented, and the plan did not know that.** Found and
written during this stage:

- **The guest half did not exist.** Nothing in the tree bound an AF_VSOCK socket
  or deserialised a `Req`. The host would boot a guest, wait five seconds for a
  socket nobody was going to open, and fail — tier 2 was a proxy talking to
  itself. `host/src/guest.rs` is the missing peer: it serves the postcard
  protocol over vsock and loads the artifact through `NativePlugin`, the same
  path tier 1 uses, so there is no second implementation of the C ABI.
- **The host half's VM launch was fabricated.** It exec'd
  `current/bin/microvm-run --vsock <path>` — an argument that script does not
  accept — and bypassed microvm.nix's orchestration entirely. Then a second
  attempt called `systemctl start microvm@<id>` from the plugin's unit, which
  fails with "Access denied" because that unit is unprivileged. The answer is
  neither: the per-instance drop-in declares
  `Requires=`/`After=`/`PropagatesStopTo=microvm@<id>.service`, so systemd
  starts the guest before ExecStart runs and takes it away when the plugin
  stops. Depending on a unit needs no privilege; starting one does.
- **Every guest got `vsock.cid = 3`**, which works for exactly one plugin. Now
  assigned by position in the sorted plugin list.
- **The declared-plugins path had never been wired to the runtime.** `plugind
  run <id>` resolved ids against the registry only, so a declared plugin's unit
  started, said "no such plugin", and died — for *every* tier, since stage 1.
  Tier 2 is what forced it: a guest needs a closure, so building one is a
  rebuild, so `declaredPlugins` is the only way a tier 2 plugin can exist. There
  is now a read-only `/etc/oligarchy/plugins/declared.json` index, and
  `declared::resolve` cross-checks the module's `tier`/`jit` against the
  artifact's own `plugin.toml` — because the sandbox drop-in was generated from
  the former before the latter was ever opened, and a disagreement means the
  plugin runs confined as something it is not.
- **The guest module did not match the stage 3 shim contract** (no store path, no
  policy, and it would have recursed by honouring `tier = "microvm"` inside the
  guest). Rewritten, with its own `guest-policy.json` permitting `native` and
  carrying the host's `minTrust`, `forbiddenPaths` and ceilings.

**`nix build .#plugins-tier2-runtime` passes.** End to end, under nested KVM:
microvm.nix materialises the guest, the drop-in generated by the **Nix** mirror
is correct (this is the first test to exercise that mirror at all, and
`MemoryDenyWriteExecute=yes` on the host side is right — tier 2's host half is a
vsock proxy that never JITs), `Requires=` boots the guest and
`PropagatesStopTo=` takes it away, the host completes the ABI Hello and calls
`init()` over the wire, and the real `.so` inside the guest reports
`WXPROBE exec=allowed memfd=allowed anon=allowed` — a self-JIT plugin getting the
executable memory it asked for, because the boundary in here is a kernel and not
a filter. That last assertion is the whole point of the tier: the identical
fixture reports `exec=denied memfd=denied anon=denied` under tier 1 with
`jit = "none"`, and the two gates run the same source file.

Four things stood between "the guest boots" and that line, and each of them
failed silently:

- **`notify.vsock` is not universal.** microvm.nix's readiness notification uses
  a *userspace* vsock behind a unix socket, which firecracker and
  cloud-hypervisor implement and **qemu does not** — qemu uses the kernel's
  vhost-vsock, where there is no socket file at all and you dial the cid.
  `connect_guest` now does both: a unix socket if microvm.nix made one, an
  `AF_VSOCK` dial by cid otherwise. The cid comes from the declared index,
  because the module is the only thing in a position to keep cids unique.
- **`vhost_vsock` was not loaded on the host.** Without it the guest's
  `AF_VSOCK` bind succeeds and nothing on the host can ever reach it. Added to
  `boot.kernelModules` in the tier 2 branch of the module.
- **The plugin unit's own sandbox blocked the transport.** A tier 2 plugin
  declaring no network still got `PrivateNetwork=yes` and
  `RestrictAddressFamilies=AF_UNIX`, which is correct for tiers 0 and 1 and
  fatal here — AF_VSOCK is how the host reaches its own guest. The tier 2 branch
  grants `AF_UNIX AF_VSOCK` and no netns, in **both** mirrors. Note this widens
  nothing outward: vsock has no route off the machine.
- **The guest's log went nowhere.** `plugind` inside the guest wrote to the
  guest's journal, which lives in a disposable VM nobody can log into.
  systemd's own console status lines escape; journald output does not. The guest
  unit now sets `StandardOutput=journal+console`, so a plugin's log reaches the
  host's `microvm@<id>.service` — which is where an operator, and this gate,
  actually look.

One diagnostic error is worth recording because it cost more than any of the
above: the guest agent *was* starting the whole time, and the conclusion that it
was not came from grepping the host journal for the unit's **name** when the
console carries its **Description**. The roadmap said "most likely
`custom.pluginGuest.enable` not taking effect", and that was wrong.

Note the test uses `microvm.hypervisor = "qemu"` while the workstation ships
`cloud-hypervisor`; nested vsock and store delivery are best-tested under qemu.
That difference is the one thing the gate does not cover — and it is exactly the
axis the first bullet above turned out to live on, so it is a real gap and not a
formality.

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

**Stage 3 leftovers**

4. `security.unprivilegedUsernsClone` writes
   `kernel.unprivileged_userns_clone`, which exists **only** on kernels carrying
   the Debian patch — zen and xanmod do, vanilla does not. On vanilla the
   governing knob is `user.max_user_namespaces`, so the build-time assertion can
   pass while the option is a no-op. It is still the right assertion (it catches
   someone forcing it off); `plugind doctor` now reports both knobs, and the
   tier 1 test asserts the one that actually governs rather than the one the
   option writes.
5. Tier 1 is verified for `native`. The **`lua`** tier compiles and is allowed,
   but nothing exercises `LuaPlugin::load` yet — the `wx-probe` fixture is C.
   A LuaJIT fixture would also be the natural place to check that `jit=self`
   actually buys compiled traces rather than the interpreter fallback.
6. **Nothing tests that the two drop-in generators agree beyond the MDWE line.**
   Both halves of the mirror gained directives during this stage and
   `NotifyAccess` plus the `AF_NETLINK` branch reached the Rust one alone —
   caught by reading, not by a test, because `checks.wx-enforcement` asserts only
   `MemoryDenyWriteExecute` and no `declaredPlugins` entry exists anywhere in
   this repo to exercise the Nix one. Both sides now route through a named
   predicate (`Manifest::uses_bwrap` / `usesBwrap`), which makes the next drift
   less likely but not impossible. The real fix is a check that renders both for
   the same set of manifests and diffs them — a `plugind dropin <manifest.toml>`
   verb plus a `runCommand` needs no KVM, so it would be the cheapest gate here.
7. `process()` is never called by anything. Both tiers implement it and the
   realtime contract is documented, but there is no audio graph yet, so the hot
   path is untested and the `#[warn(dead_code)]` list is long for a real reason.

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

**Stage 4 (tier 2) leftovers**

8. **The gate runs qemu; the workstation runs cloud-hypervisor.** Those two
   hypervisors reach a guest by *different transports* — kernel vhost-vsock
   versus a userspace vsock behind a unix socket — and that difference was one
   of the four bugs this stage had to fix. `connect_guest` handles both, but
   only the qemu branch is exercised by a gate. The cheapest fix is a second
   node in `tier2-runtime` with `hypervisor = "cloud-hypervisor"`; nested
   cloud-hypervisor under the NixOS test driver is the open question.
9. `vm-manager/` has no microvm.nix dependency today (its four guests are
   quickemu/QEMU), so there is no option collision to resolve — but the two
   will be managing VMs on the same host and that interaction is unexercised.
10. **`cidOf` assigns cids by position in the sorted plugin list**, so adding a
    plugin whose name sorts early renumbers every guest after it. Harmless
    today (the cid is regenerated into `declared.json` by the same rebuild) but
    it means a cid is not a stable identifier, and anything that starts
    remembering one — a log, an operator's notes, a firewall rule — will be
    wrong after an unrelated rebuild.
11. **A guest is a full NixOS closure per plugin.** That is the honest cost of
    the tier and not a defect, but nothing warns an operator that enabling
    tier 2 for four plugins means four system closures and four rebuilds.

---

## 7. Changelog

- **Stage 1** — vendored `oligarchy-plugins` as a sub-flake; generated
  `host/Cargo.lock`; fixed the wasmtime 43 / landlock 0.4 API drift; fixed the
  NixOS-specific defects in the module (drop-in mechanism, supervisor
  privileges); wired tier 0 onto `nixosConfigurations.nixos`.
- **Stage 2** — signed registry + unprivileged imperative install over a
  group-owned control socket. Found and fixed a critical hole: `nix store
  verify --sigs-needed 1` short-circuits for content-addressed paths, and
  `nix store add-path` needs no privilege, so on its own it accepted arbitrary
  attacker-authored content as verified. Verification now requires a signature
  naming a pinned key *and* `nix store verify`. Nobody was added to
  `trusted-users`.
- **Stage 3** — tier 1 (`native`/`lua`) under bwrap + Landlock + seccomp. Seven
  separate settings each broke it silently (`RestrictNamespaces`,
  `RestrictAddressFamilies`, `ProtectKernelTunables`, `NotifyAccess`, the
  `/state`,`/config` remapping, the root-owned registry, the unbound policy
  file); all are documented at the point that fixes them.
- **Stage 4** — closed three confirmed W^X bypasses that made stage 3's claim
  false (see §4.1), implemented tier 2 including the guest agent that had never
  existed, and wired the declared-plugin path that had been broken for every
  tier since stage 1. All five gates pass.

# oligarchy-plugins

An imperative plugin system for [Oligarchy](https://github.com/ALH477/Oligarchy),
delivered as a Nix flake module. One ABI across WASM, native and Lua plugins;
three sandbox tiers chosen per-plugin from a capability manifest; and
per-instance W^X enforcement, so a plugin that genuinely needs a JIT can have
one without every other plugin on the machine inheriting the concession.

## The problem this solves

"Sandbox the applications" and "support JIT" are in direct tension. Every
serious executable-memory mitigation — systemd's `MemoryDenyWriteExecute`,
SELinux `execmem`, kernel lockdown — works by refusing to let a process turn
writable bytes into executable ones. That is exactly what a JIT does. Turn the
mitigation on and LuaJIT, PCRE-JIT, V8 and .NET all break. Turn it off and you
have conceded the category for everything on the box.

Worse, `MemoryDenyWriteExecute` is bypassable by construction. Drepper's
dual-mapping — `memfd_create`, then two `mmap`s of the same fd, one
`PROT_WRITE` and one `PROT_EXEC` — never produces a single W+X mapping, so the
filter never fires. systemd knows; issue #11473 has been open about it for
years. Any JIT that wants through, gets through.

So the answer is not to pick a side. It is to make the decision **per plugin,
declaratively, at the unit level**, and to route the cases where the answer is
genuinely "no" somewhere the answer doesn't have to hold on the host.

## The design

```
                    plugin.toml  ──►  policy.json  ──►  tier router
                    (what the        (what the host      (the only
                     plugin asks)     permits)            decision point)
                                            │
        ┌───────────────────────────────────┼───────────────────────────────┐
        ▼                                   ▼                               ▼
  Tier 0  wasm                        Tier 1  native / lua           Tier 2  microvm
  wasmtime + WASI                     bwrap + landlock + seccomp     firecracker / chv
  Cranelift JITs in the HOST          PROT_EXEC per manifest         own guest kernel
  guest never needs PROT_EXEC         cgroup v2 caps                 vsock transport
  MDWE=yes, always                    MDWE from manifest             W+X lives in the VM
        │                                   │                               │
        └───────────── one WIT world: oligarchy:plugin@0.1.0 ───────────────┘
```

| | Tier 0 wasm | Tier 1 native/lua | Tier 2 microvm |
|---|---|---|---|
| memory safety | by construction | none | guest kernel boundary |
| unit `MemoryDenyWriteExecute` | **no** (host JITs) | from `jit` | yes (host side proxies only) |
| `PROT_EXEC` in guest | never needed | per manifest | irrelevant |
| realtime-safe | yes | yes | **no** |
| startup | sub-ms (pooling alloc) | ~ms | ~125 ms + guest init |
| use for | anything you didn't write | CLAP/LV2/Faust hot path | untrusted + self-JIT |

The three-way `jit` field is what makes this tractable:

- **`jit = "none"`** — no runtime codegen. `MemoryDenyWriteExecute=yes`, *and*
  `memfd_create` denied, because MDWE alone leaves the dual-mapping hole open.
  Applies to `native`/`lua`, where the plugin's machine code shares plugind's
  address space and syscall access.
- **`jit = "host"`** — Cranelift compiles the plugin in *our* address space,
  with *our* privileges, from code already proven type-safe by validation.
  Note the consequence, which is easy to get backwards: the Tier 0 unit runs
  with `MemoryDenyWriteExecute=**no**`, because *this process* is the one
  doing the compiling. Setting MDWE there would break Tier 0 outright while
  hardening nothing — a wasm guest cannot issue a syscall at all except
  through host functions we wrote. The boundary is wasmtime, not seccomp.
- **`jit = "self"`** — the plugin carries its own code generator.
  `MemoryDenyWriteExecute=no` for **that systemd instance only**. Everything
  else tightens to compensate: Landlock down to the plugin's own directories,
  network denied, hard cgroup caps. And if the plugin is also `untrusted`,
  manifest validation *refuses to load it outside tier 2* — the one thing this
  design will not do is hand W^X to unreviewed code on the host.

## Imperative install on a declarative system

NixOS is declarative. You asked for imperative. The seam is drawn deliberately:

**Declarative** (in the flake, reviewed, rolls back with the system):
the policy, the `plugind` binary and its closure, the systemd template unit,
the state directory layout, the trusted public keys.

**Imperative** (mutable, at runtime, no rebuild):
which plugins exist, which are enabled, their config.

```console
$ plugind install oligarchy-fx#tape-saturator
installed demod-tape-saturator
demod-tape-saturator v1.2.0
  tier    Native
  jit     SelfJit
  trust   Trusted
  W^X     NOT enforced (jit=self)
  isolate bwrap namespaces + landlock + seccomp + cgroup v2
  network denied
  rt-safe true
  policy  PERMITTED
run `plugind enable demod-tape-saturator` to start it
```

A systemd *template* unit can't vary `MemoryDenyWriteExecute` per instance, so
`plugind enable` writes a drop-in to
`/run/systemd/system/oligarchy-plugin@<id>.service.d/10-sandbox.conf` and
reloads. `/run` is tmpfs — which is the point. **The drop-ins evaporate on
reboot and are regenerated from the registry**, re-authorised against current
policy. A W^X grant cannot outlive the decision to make it, and a
`nixos-rebuild` that tightens policy takes effect on next boot without anyone
having to remember to re-check.

### Trust: caches, not users

Nobody gets added to `nix.settings.trusted-users`. From the Nix manual, that is
*equivalent to giving that user root access to the system*. Instead the FX
Bazaar is a **signed binary cache** in `trusted-substituters` with its key in
`trusted-public-keys`, and every path is `nix store verify`'d before it is
registered. An unprivileged user can install a signed plugin and cannot install
anything else. Installed paths get a GC root so `nix store gc` can't delete a
plugin out from under a running rig.

## Use it

```nix
{
  inputs.oligarchy-plugins.url = "github:ALH477/oligarchy-plugins";

  # in your nixosConfiguration:
  imports = [ inputs.oligarchy-plugins.nixosModules.default ];

  custom.plugins = {
    enable = true;

    # Default posture: wasm only, no self-JIT, signatures required.
    # This is what a stage rig or a shipped guitar should run.
    allowedTiers = [ "wasm" ];
    allowSelfJit = false;

    substituters      = [ "https://cache.demod.ltd" ];
    trustedPublicKeys = [ "cache.demod.ltd-1:..." ];
  };
}
```

Workstation posture, where you want native DSP and your own JIT-ing plugins:

```nix
custom.plugins = {
  enable = true;
  allowedTiers = [ "wasm" "native" "lua" ];
  allowSelfJit = true;          # emits a build warning; that's intentional
  minTrust = "trusted";         # refuse anything unsigned by a known author
  microvm.enable = true;        # so untrusted+self-JIT has somewhere to go
  microvm.hypervisor = "cloud-hypervisor";
};
```

The module's assertions catch the incoherent combinations at **build** time —
`tier = "wasm"` with `jit = "self"`, an untrusted self-JIT plugin with no
microVM to put it in, a tier that isn't in `allowedTiers`, `requireSignature`
with no keys — so you find out during `nixos-rebuild`, not during a set.

## Layout

```
flake.nix                     nixosModules.{plugins,default,microvmGuest}, checks
modules/plugins.nix           custom.plugins.* — policy, units, state, assertions
wit/oligarchy-plugin.wit      the ABI. Single source of truth for all three tiers
host/include/oligarchy_plugin.h   CLAP-style stable C vtable — the native projection
host/src/
  manifest.rs                 plugin.toml schema + the tier/jit invariants
  policy.rs                   the host's answer to the manifest's request
  registry.rs                 THE SEAM: nix resolution, signatures, /run drop-ins
  plugin.rs                   the common trait every tier implements
  sandbox/seccomp.rs          the conditional W^X filter
  sandbox/landlock.rs         FS/net allowlist, ABI v1–v8 with BestEffort degradation
  sandbox/bwrap.rs            namespace setup for tier 1
  tiers/{wasm,native,lua,microvm}.rs
examples/                     one manifest per tier, including the self-JIT case
```

## Verify it actually works

`nix flake check` runs two VM tests. The first is the one that matters: a unit
test can only prove we *built* the right BPF program, so `checks.wx-enforcement`
boots a real kernel and asserts that a `jit=none` plugin gets
`MemoryDenyWriteExecute=yes`, that a `jit=self` plugin gets `no` *with the
reason recorded in the unit where an auditor will see it*, and that the grant
does not survive a reboot. `plugind doctor` reports what the running kernel can
actually enforce; there's a `#[cfg(debug_assertions)]` self-test that forks and
attempts `mprotect(PROT_EXEC)` to confirm the filter took, because a silently
un-installed seccomp filter is the worst possible failure mode here.

## Review pass

A second pass found and fixed the following; they're listed because the first
three would have shipped broken and the reasons are worth knowing:

1. **`MemoryDenyWriteExecute=yes` on Tier 0 units.** The drop-in generator keyed
   off `jit != self`, so a `tier=wasm, jit=host` unit got MDWE — which would
   have stopped Cranelift publishing compiled code and broken Tier 0 silently,
   while hardening nothing. W^X is now a function of tier *and* jit
   (`Manifest::wx_enforced`), mirrored in Nix as `wxEnforced`, with a
   regression test in `checks.wx-enforcement`.
2. **`Type=notify` + `--unshare-all`.** Abstract unix sockets are per-network-
   namespace, so an abstract `NOTIFY_SOCKET` can never be reached from inside
   the bwrap sandbox and the unit dies on timeout with an unhelpful message.
   `bwrap.rs` now binds a pathname notify socket and refuses to start when
   systemd hands it an abstract one.
3. **Two simultaneous `&mut` borrows of the argv vector** in `bwrap.rs` — two
   closures both capturing it mutably. Did not compile. Replaced with a small
   builder.
4. `landlock.rs` computed network-enforcement availability from the *target*
   ABI rather than the running kernel, making it a tautology and silently
   disabling the netns fallback on every kernel below 6.7.
5. `WasmPlugin::load` passed `store_path` for both `state_dir` and
   `store_path`, so `$STATE` expanded into the read-only Nix store.
6. `Plugin::params(&self)` forced a `&self`→`&mut self` cast in the microVM
   tier. Signature changed to `&mut self`; the cast is gone.
7. `WasmPlugin` handed out unlimited processors, each holding `&mut Store`.
   Now capped at one, enforced.
8. `NativePlugin` declared its `Library` first, so `dlclose` ran while the host
   vtable pointing into it was still live. Moved last.
9. The seccomp self-test called `std::process::exit` in a forked child of a
   multithreaded process. Now `_exit`.
10. mlua 0.10 dropped the two-generic `get::<K,V>`/`call::<A,R>` form; the code
    was written in 0.9 style throughout. Also `StdLib::JIT` was missing, so the
    LuaJIT status diagnostic always reported "off".
11. Drop-ins were routed through `systemd.units`, which is keyed by unit name
    and rejects `foo.service.d/bar.conf`. Now `environment.etc`.
12. `flake.nix` referenced `modules/guest.nix` (didn't exist) and both VM tests
    asserted against `/etc/oligarchy/test/*` fixtures nothing ever created.
    Both fixed.
13. `pkgs/plugind` set `buildFeatures` against a `[features]` section that
    didn't exist, and hardcoded `sourceRoot = "source/host"` under a
    `cleanSourceWith` that names the store path.
14. Minor: the microVM vsock lacked its `CONNECT <port>` handshake; `reset()`
    faked itself through a sentinel param id; the epoch ticker thread leaked;
    `--option extra-substituters ""` didn't do what its comment claimed
    (`accept-flake-config false` does).

## Still not compile-verified

There's no Rust or Nix toolchain in the environment this was written in, so
treat it as a reviewed design with plausible syntax rather than a build that's
known green. The places most likely to need adjusting:

- **`seccompiler` 0.4 and `landlock` 0.4 API surfaces.** Both have moved
  between minor versions. The `SeccompFilter::new` arity and the
  `Ruleset` builder chain are the two spots to check first.
- **`wasmtime` 43 vs 46.** `bindgen!` output and the `WasiView` split have
  changed across recent releases; the version is pinned to the minor in
  `Cargo.toml` for exactly this reason. WASI 0.3 landed June 2026 and is
  default-on in 46, which will move the `wasmtime-wasi` imports.
- **`microvm.nix`'s `vsock.cid` handling**, which I've stubbed as `null` for
  host assignment.
- `Cargo.lock` doesn't exist yet, so `pkgs/plugind/default.nix` won't evaluate
  until you `cargo generate-lockfile`.

`cargo test` covers the parts that don't need a toolchain to reason about: the
manifest invariants, the policy refusals, and the shape of the two seccomp
programs.

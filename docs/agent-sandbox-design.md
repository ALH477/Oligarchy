# Agent sandbox design — per-task containers, long-lived identities

Answers the design question the kernel roadmap's Phase K5 leaves open
(`docs/exsecutor-kernel-roadmap.md` §K5: "a design answer for per-task
sandboxes, since the existing tier is declarative-only").

## The constraint

Two sandbox substrates exist in this repo, and they have opposite
shapes:

| | forge (rootless podman) | plugin tier 2 (microVM) |
|---|---|---|
| Lifecycle | per-invocation (`--rm`) | declarative, long-lived |
| Identity | none — the container IS the task | pinned in the system closure |
| Boundary | namespaces + seccomp + Landlock on a shared kernel | guest kernel (VMX non-root) |
| Closure cost | image built per project, cached | full NixOS closure per plugin, rebuilt |
| Trust model | agent output is untrusted INPUT, not code | plugin binary is untrusted CODE |

A per-task agent sandbox cannot be a tier-2 microVM: a guest needs a
closure, building one is a rebuild, and a task is created from a
mutable workspace at request time. The tier is declarative-only by
construction, and that is not a defect to fix — it is what makes the
guest's closure pinned and reviewable.

## The answer: split the two lifecycles

An agent sandbox has two halves with different lifetimes:

<!-- truth:claim
id: forge-posture-defaults
kind: file_contains
path: modules/oligarchy-forge/crates/forge-core/src/schema.rs
pattern: default_true
-->
- **The task** — the unit of work. Ephemeral, created from the
  workspace, destroyed on completion. Runs in a **forge container**
  (rootless podman), now locked down by default in
  `modules/oligarchy-forge/crates/forge-core/src/schema.rs`: read-only
  rootfs, strict seccomp, `--network=none`, cgroup limits
  (`docs/oligarchy-forge-roadmap.md` §7). The task half is where
  model output executes; it is untrusted input and the container is
  the right boundary for that.
<!-- truth:end -->
- **The identity** — the agent's credentials, config, and any
  long-lived state. Long-lived, declarative, pinned in the closure.
  This is where a **tier-2 microVM** belongs when the agent needs a
  kernel boundary (self-JIT, native toolchains): one guest per agent
  identity, declared in `custom.plugins.declaredPlugins` with
  `tier = "microvm"`, `jit = "self"`, `trust = "untrusted"`
  (see `docs/plugins-roadmap.md`, "Agent-sandbox shape").
<!-- truth:claim
id: tier2-microvm-channel
kind: file_contains
path: modules/oligarchy-plugins/host/src/tiers/microvm.rs
pattern: GUEST_PORT
-->
The task container talks to the identity guest over the plugin tier's
existing vsock channel in `modules/oligarchy-plugins/host/src/tiers/microvm.rs`
(length-prefixed postcard on a fixed guest port).
<!-- truth:end -->

The identity guest holds the credentials; the
task container never sees them. This is the roadmap's design principle
3 ("keep credentials outside the sandbox; inject scoped tokens at a
proxy") applied to the two-substrate split.

## What is NOT yet built (the honest list)

1. **The mediator.** The vsock channel's host side is a plugin host,
   not a policy decision point. K5's "host-side mediator applying
   capability checks" is the missing piece that makes the split more
   than a topology.
2. **The egress proxy.** `--network=none` on the task container means
   NO egress — correct as a default, but a coding agent that needs to
   fetch needs the allowlist proxy (K5 deliverable), holding
   credentials and injecting scoped tokens.
3. **In-guest layering.** The tier-2 guest currently downgrades to
   native inside the guest. bubblewrap + Landlock in-guest is the
   defence-in-depth layer (K5 deliverable).
4. **The task→identity handoff.** Nothing wires a forge task to an
   identity guest yet. The vsock channel exists; the orchestration does
   not.

## Why not just use the forge for everything

Because the forge's boundary is a filter on a shared kernel. A kernel
exploit inside a forge container is a host-kernel bug. A tier-2 guest's
boundary is a guest kernel; the host sees only the VMM's filtered
syscalls. For an agent that compiles and runs its own code (self-JIT,
`jit = "self"`), the microVM is the only tier whose boundary is not a
filter — and the forge's locked-down posture (10 new flags, all
default-on) is what makes the per-task half acceptable in the
meantime.

## What this document does not claim

No performance numbers are given: the task→identity vsock hop's cost
has not been measured. The topology is a design answer to K5's open
question, not a benchmark. `[UNTESTED]` for the handoff;
`[MEASURED]` for the forge posture flags (see
`docs/oligarchy-forge-roadmap.md` §7) and the tier-2 substrate (see
`docs/plugins-roadmap.md` stage 3).

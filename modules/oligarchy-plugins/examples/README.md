# Example manifests

Five examples, each carrying one lesson. Read `dcf-talk` and `hello-control`
first — they are what a plugin normally looks like.

| Example | Tier | `jit` | Exports `dsp`? | The lesson |
|---|---|---|---|---|
| [`dcf-talk`](dcf-talk/) | `lua` | `none` | **no** | A real application. Chat + voice over DCF, driven entirely through the control surface. The only example that asks for the network — and does not get it by default. |
| [`hello-control`](hello-control/) | `wasm` | `host` | **no** | The floor. The smallest thing that is a valid plugin. Start here and add only what you need. |
| [`gain`](gain/) | `wasm` | `host` | yes | The optional audio extension in the default tier. |
| [`lua-lfo`](lua-lfo/) | `lua` | `none` | yes | Same tier as `dcf-talk`, opposite shape — proof that `dsp` is a property of the artifact, not of the tier. |
| [`tape-saturator`](tape-saturator/) | `native` | `self` | yes | Why per-instance W^X exists at all. The only manifest here that turns `MemoryDenyWriteExecute` off, for its own systemd instance and nothing else on the machine. |

## Why this set changed

It used to be three examples and all three were audio effects. That taught the
wrong thing twice over.

The first mistake was in the ABI, not the examples: `world plugin` mandated
`export dsp`, so every plugin *had* to be an audio effect whether it had samples
to touch or not. `tests/wx-probe.c` — a sandbox probe with no audio in it
anywhere — had to carry a stub `process()` that copied its input to its output,
purely to satisfy the export. `dsp` is now optional (see
`docs/plugins-roadmap.md` §4.2), and three of the five examples below still
export it because audio plugins are a real thing — just not the default thing.

The second mistake was pedagogical. **Realtime audio on this system belongs to
the RT VM engine**, not to a plugin: the ArchibaldOS DSP guest has an isolated
core (`isolcpus=0`), a realtime kernel, kexec recovery and NETJACK. A plugin is
dlopen'd into a bwrap + Landlock + seccomp process where a sample-rate deadline
has no business living. `host/src/plugin.rs` had already reasoned out half of
this — Tier 2 is disqualified from the hot path because a vsock hop is in the
way — without anyone noticing the argument generalises.

`dcf-talk` is the sharpest illustration. It carries **voice**, and it still
exports no `dsp`: DCF's voice path is its own transport (capture → L2 →
jitter/PLC/DTX → playout over 17-byte `DeModFrame`s) and it never asks the host
for a `process()` callback. Audio passing *through* a plugin is not the same
thing as a plugin being an audio effect.

## The two axes that matter

Every manifest picks a point in this space, and the sandbox is generated from
that choice rather than from anything the plugin does at runtime:

- **`tier`** decides the isolation — wasmtime, bwrap+Landlock+seccomp, or a
  separate kernel.
- **`jit`** decides W^X. `none` means `MemoryDenyWriteExecute=yes` plus a
  seccomp filter closing six other routes to executable memory; `self` means the
  concession, for that instance only, and only if the operator set
  `allowSelfJit`.

`dsp` is a third, independent axis, and it is a property of the **artifact** —
the host discovers it by asking, not by reading the manifest. `lua-lfo` and
`dcf-talk` are the same tier and the same `jit` and differ only there.

## Note on the audio three

`gain`, `lua-lfo` and `tape-saturator` are manifests without artifacts, apart
from `lua-lfo/lfo.lua`. They are illustrative: the point is the capability
declaration and what the module does with it, not the DSP. `tape-saturator` in
particular exists to be read next to `modules/plugins.nix` — it is the manifest
that has to clear three independent declarative gates (`allowSelfJit`,
`allowedTiers`, `minTrust`) before it loads at all.

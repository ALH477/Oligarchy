# DCL — Nix integration

The Nix consumption side of the DeMoD Configuration Layer
(`demod-config-layer-spec.md`). Pure evaluation: no IFD, no `--impure`, no
derivation, no KVM.

| File | Role |
|---|---|
| `dcl.nix` | The library. `load` / `loadOrThrow`, plus `internal` for the gate. |
| `nixos-module.nix` | `custom.dcl.*` — makes values readable by ordinary modules. |
| `schema.json` | The §12 worked example, used as the gate's own fixture. |
| `test.nix` | 24 library tests. |
| `module-test.nix` | 7 module-surface tests via `lib.evalModules`. |
| `test/fixtures/` | One directory per failure mode. |

## Use

```nix
{ config, ... }: {
  custom.dcl = {
    enable = true;
    dir = inputs.guitar-config;   # §7.2: its OWN repo, never the user's
  };

  # Defaults are already merged — never test for key presence (§4.2).
  services.foo.sampleRate = config.custom.dcl.settings."engine.sample_rate";
}
```

## Gate

```bash
nix build .#dcl-check      # cheap: pure eval, runs on every change
```

Verified to fail, not just to pass: breaking a `default` out of its own range
turns 9 of the 31 tests red and names each one.

`modules/dcl/` must be **git-tracked** or flake evaluation cannot see it —
`git add` new fixtures before running the gate. This is the same constraint
§7.2 is built around.

## Where this deliberately departs from the spec

The spec's §7.3 snippet does not hold up; this is not a transcription of it.
Each item below is a defect in the spec that the code works around, and the
spec should be corrected to match.

- **§7.3 `readFile` is unguarded.** §4.3 and the §14 checklist both require a
  `pathExists` guard; the code sample omits it. An absent `values.json` is the
  all-defaults state, and under flake evaluation an *untracked* one is
  indistinguishable from absent.
- **§7.3 compares before it type-checks.** `v >= o.min` on a hand-edited
  `"loud"` throws `cannot compare a string with an integer`, not the readable
  message §5.1 promises. Type is checked first here.
- **§7.3 validates neither `step` nor string constraints.** §3.2 calls `step`
  normative *for the validator*, not just the GUI, and §3.4 defines
  `pattern`/`max_length`. Omitting them lets a file pass the build and then
  quarantine on the device — the two consumers disagreeing about one file.
- **§3.2 never says where the step grid is anchored.** Anchored at `min` here,
  matching §8.4's `snap`. Anchoring at zero is equally readable from the spec
  and disagrees whenever `min` is off a zero-based grid (`min = -20,
  step = 0.3`).
- **§13 has no divisibility check.** When `(max - min)` is not a multiple of
  `step`, §8.4's `snap` rounds *past* `max`: with `min=0, max=10, step=4`,
  dragging a slider to its own maximum yields 12 and a range error. Caught at
  schema-load here, so no walker has to clamp.
- **§5.3 messages vs. Nix float rendering.** `toString 40.0` is `40.000000`,
  which is not the user-facing quality §5.3 demands and not what the spec's own
  example shows. Numbers are trimmed to their shortest exact form.
- **§13's `--values ${./values.json}`** cannot work on a deployment §4.3
  declares legal (no `values.json` at all) — it fails at eval on a missing
  path. The gate here takes a directory and tolerates absence.

Unknown keys are reported as **warnings** and excluded from `settings`. Nix
cannot write, so it cannot quarantine (§4.4); what it must not do is let a key
through that libdmc would have refused.

## Still missing

`libdmc` does not exist yet. Once it does, `dmc-validate` and this library are
two implementations of one contract, and they must be diffed against the same
fixtures — any check one makes and the other does not is exactly the
build-passes / device-quarantines split above. The fixtures here are shaped to
be reusable as libdmc's.

Not implemented on this side, and correctly so: migration (§6 — lives in
libdmc and only there), quarantine persistence, and `must_exist` path checks
(§3.5 — apply time, not eval time).

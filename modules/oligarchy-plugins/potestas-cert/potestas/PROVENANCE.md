# modules/oligarchy-plugins/potestas-cert/potestas/ — provenance

`potestas.gen.c` is **generated**. Do not edit it. It is the C11 library unit
that the Exsecutor compiler emits from one Exsecutor source file:

| | |
|---|---|
| Exsecutor repository | `github.com/ALH477/exsecutor` |
| Commit | `711c19d1a1507b100b0ce675824fcdbbb3cf4e43` (branch `wt/potestas`; not yet on upstream `main`) |
| Source | `examples/potestas/potestas.exsc` (with its README and `potestas.h`) |
| Command | `exsc aedifica --hospes x86_64-linux --emitte c examples/potestas/potestas.exsc -o potestas.gen.c` |
| Output | 60,048 bytes, sha256 `4db18a47484c5e04b703f13a407d7efcc7b191e5d4fc7e9092089d6a81491fed` |

The unit states plugind's install-time policy facts that are pure functions
of bytes:

- the id grammar;
- the lexical half of the forbidden-path check, in both directions;
- the fs-capability anchor rule;
- the W^X rule.

It is pure under Exsecutor's capability rules (spec §4.1 rule 6: no `poscit`
and no capability parameter). Upstream, `examples/potestas/proba_c.sh` checks
three things:

- 122 anchors pass under gcc and clang;
- 16 behaviour mutants are each caught;
- an ambient draw is refused with `EXS-E0421`, and a capability parameter
  breaks the C prototype in `potestas.h`.

`regen.sh` re-emits the file from an Exsecutor checkout and compares the
result with this copy. `../build.rs` compiles `potestas.gen.c` and `shim.c`
with the `cc` crate. `shim.c` supplies the unit's one import,
`exsrt_abortus`, which stops the process. The only caller is the test-only
crate this directory belongs to. **plugind does not link this unit.** Its
derivation's source filter admits only `host/` and `wit/`, and its
`Cargo.toml` does not name this crate.

**Licence.** The file is compiler output, covered by Exsecutor's
`LICENSE.EXCEPTION` Exception A: it may be propagated under terms of the
recipient's choosing. It ships here under this crate's MPL-2.0 licence. No
Exsecutor source is copied into this tree.

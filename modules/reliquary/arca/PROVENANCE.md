# modules/reliquary/arca/ — provenance

`arca.gen.c` is **generated**. Do not edit it. It is the C11 library unit the
Exsecutor compiler emits from one Exsecutor source file:

| | |
|---|---|
| Exsecutor repository | `github.com/ALH477/exsecutor` |
| Commit | `bd10e83d26a8dd7983e2b6ea180808ac7ae5263b` |
| Source | `examples/arca/arca.exsc` (the tar-header judge, and its README) |
| Command | `exsc aedifica --hospes x86_64-linux --emitte c examples/arca/arca.exsc -o arca.gen.c` |
| Output | 63,400 bytes, sha256 `2d654f98e8cc04950e8d2375812264c273a610ddc50a359d6c14b4941d4e8702` |

The judge is pure under Exsecutor's capability rules (spec §4.1 rule 6: no
`poscit`, no capability parameter). Upstream, `examples/arca/proba_c.sh` shows
two things:

- an ambient draw is refused with `EXS-E0421`;
- a capability parameter breaks the C prototype `arca.h` pins.

The same script holds the judge to GNU tar itself:

- reliquary's own archives are admitted, and the member lists equal
  `tar -tvf`'s;
- 32 hostile archives are refused;
- a header fuzz produces zero cases the judge admits and GNU tar reads
  differently.

`regen.sh` re-emits the file from an Exsecutor checkout and compares the
result. `build.rs` compiles `arca.gen.c` and `shim.c` (the unit's one import,
`exsrt_abortus`, which stops the process) with the `cc` crate. `src/arca.rs`
is the only caller.

**Licence.** The file is compiler output, covered by Exsecutor's
`LICENSE.EXCEPTION` Exception A: it may be propagated under terms of the
recipient's choosing, and it ships here under this crate's MIT licence. No
Exsecutor source is copied into this tree.

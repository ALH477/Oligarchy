# The policy compiler — the first step

`docs/exsecutor-kernel-roadmap.md` names the build-time policy compiler as the
most valuable thing that can be built now: one declaration, lowered to
Landlock rulesets, seccomp filters, a systemd drop-in and later IPE policy
(finding 7 and Phase K1). This document covers the first step toward it.

That step **decides; it does not yet emit.** It takes four facts that
plugind decides at install time and states them once, in a pure Exsecutor
unit. It then certifies that unit, differentially, against plugind's own
functions and against the Nix mirror of the W^X rule. Nothing in plugind's
build or behaviour changed.

Claims here are not TrvthNvke-gated (this file is not in `.trvthnvke.toml`'s
`[[docs]]` list). Exsecutor statements are pinned to a commit, as in the
kernel roadmap.

## 1. What exists

**The unit.** It lives in Exsecutor at `examples/potestas/potestas.exsc`,
commit `711c19d` on branch `wt/potestas`, which is not yet upstream. The
emitted C is vendored here as
`modules/oligarchy-plugins/potestas-cert/potestas/potestas.gen.c`, and that
directory's `PROVENANCE.md` and `regen.sh` record how to re-emit it. Each
public function is the exact rule of one plugind function:

| fact | plugind | Exsecutor |
|---|---|---|
| the id grammar, 1..=64 of `[A-Za-z0-9_-]`, length judged first | `manifest::check_id` | `titulus_iudica` |
| is a path at or under a prefix, by components | `policy::is_under` | `subest` |
| the lexical half of the forbidden-path check, both directions | `policy::overlaps`, before canonicalisation | `tangit` |
| an fs capability is anchored (absolute, or `$STATE`/`$CONFIG`/`$STORE`) | `Manifest::validate` | `ancora` |
| W^X enforced, W^X conceded, bubblewrap tier | `Manifest::wx_enforced`, `grants_wx_to_plugin`, `uses_bwrap` | `wx_cogitur`, `wx_conceditur`, `involucrum` |

The unit is pure under Exsecutor spec §4.1 rule 6: it has no `poscit` row and
takes no capability parameter. It allocates nothing and reads fixed buffers.
An id buffer is 64 bytes and a path buffer 4,096 bytes, and a length past the
buffer is answered before any byte is read. Upstream, `proba_c.sh` checks the
following:

- 122 anchors under gcc and clang, at `-O0` and `-O2`, with UBSan;
- 16 behaviour mutants, each caught by an anchor;
- an ambient draw of `ambitus` or `archivum`, refused as `EXS-E0421`;
- a `Scriptor` parameter, which breaks the pinned C header.

**The certification.** `modules/oligarchy-plugins/potestas-cert/` is a crate
used only for testing. Its `tests/certify.rs` includes plugind's
`host/src/manifest.rs` and `host/src/policy.rs` verbatim with `#[path]`, so the
functions under test are plugind's source, not copies. It links the
vendored unit through `build.rs` and the `cc` crate.

Three things keep it out of plugind:

- plugind's derivation (`pkgs/plugind/default.nix`) filters its source to
  `host/` and `wit/`;
- plugind's `Cargo.toml` does not name this crate;
- `cc` is a build dependency of this crate alone.

Run it with:

```sh
cd modules/oligarchy-plugins/potestas-cert && cargo test --release
```

The run in the commit that added it took about a minute and produced these
results:

| family | compared against | inputs | disagreements |
|---|---|---|---|
| ids | `check_id` | 2,326,062. Every byte value, every Unicode scalar value (1,112,064, alone and after a prefix), every length to 130, and a 100,000-id fuzz. A further 512 non-UTF-8 inputs, which `check_id` cannot receive, were all refused by the unit. | 0 |
| paths | `Policy::authorize`, one cap against one forbidden prefix | 5,957,344 pairs. 8,624 caps × 656 forbidden prefixes, built from the components `"" . .. proc etc secrets secrets.d home homework` up to depth 3 under six leads (`/ // /./ "" ./ $STATE/`) with and without a trailing slash, plus plugind's own test vectors and a 300,000-pair token fuzz. | 0 |
| anchors | `Manifest::validate` | 121,247 caps | 0 |
| W^X | `wx_enforced`, `grants_wx_to_plugin`, `uses_bwrap` | all 12 tier × jit rows | 0 |
| Nix mirror | `wxEnforced`, `grantsWx`, `usesBwrap`, evaluated from `modules/plugins.nix` by `nix-instantiate` | 12 rows, against Rust and Exsecutor | 0 |

The path family compares the lexical half exactly. `authorize` reports *how*
a cap overlaps a forbidden prefix, and `overlaps` tries the unresolved pair
before either canonicalised one. So "is under" and "contains" appear exactly
when the lexical half fires. The harness rebuilds the whole message for each
possible answer, so no path spelling can pass for another answer. A
"resolves to …" answer means the lexical half said no and the filesystem said
yes; that half stays in Rust, and the harness counts it (2 in this run)
instead of comparing it.

**It cannot pass vacuously.** Every family has floors, for the total compared
and for each verdict class. Six mutated units were each swapped in for the
vendored one, and each produced disagreements:

| mutant | disagreements | test that failed |
|---|---|---|
| the "contains" direction dropped | 1,176,189 | paths |
| `.` components kept | 53,469 | paths |
| a prefix's leading `.` matched | 11,079 | paths |
| `-` swapped for `.` in the id grammar | 3,757 | ids |
| the `$STORE` anchor dropped | 156 | anchors |
| W^X on a wasm unit | — | the 12-row W^X test |

The Nix check fails when `nix-instantiate` is missing. Skipping it takes
`POTESTAS_SKIP_NIX=1`, and the skip is printed.

## 2. What this proves, and what it does not

It proves four things:

- On that corpus, one capability-free statement of the four facts gives
  plugind's own answers, bit for bit.
- The W^X rule's three statements agree on every row: Rust, Nix, and
  Exsecutor. Until now, the agreement between Rust and Nix rested on a comment
  asking that the two be kept in step.
- The unit cannot observe the host. Exsecutor's checker enforces that, not a
  review.
- A future plugind could call the unit for these facts without changing any
  verdict on the corpus.

It does not prove these:

- **That plugind uses the unit.** It does not. plugind still runs its own
  Rust; this is certification, not substitution. Linking the unit into
  plugind would put `cc` and an FFI boundary in a root daemon. That is a
  reviewed change for a later step, and its justification would be this
  harness. `[OPEN]`
- **Agreement outside the corpus.** A differential run is evidence, not a
  proof. The components were chosen to hit every rule `is_under` states, and
  each mutant above shows the corpus reaches a rule. Still, depth stops at 3
  and the fuzz is seeded.
- **Anything about the artifacts.** The drop-in, the Landlock ruleset and the
  seccomp filter are still produced by hand-written code. `.#plugins-*` gates
  those; this harness does not.
- **The symlink half of `overlaps`.** It stays in Rust, as section 4 says.

### A finding: the check runs on a spelling that is not the one enforced `[OPEN]`

This was found while writing the corpus, and reproduced against plugind's
own `authorize` and `expand`. It has been reported, not fixed here.

`Policy::authorize` judges the capability string as written. The launch path
judges something else. `sandbox::prepare` (Landlock), `bwrap::plan` and the
wasm preopens open `Manifest::expand(cap)` instead. `expand` substitutes
`$STATE`, `$CONFIG` and `$STORE` anywhere in the string, and the result is
opened through symlinks.

Two spellings pass `authorize` under the default policy with the native
tier allowed:

- `"$STATE/x"`, where `x` is a symlink to `/proc` that an earlier version of
  the same plugin planted in its own read-write state directory. State
  survives reinstall and `remove`.
- `"/home$STORE"`, which expands to `/home/nix/store/<hash>-<name>`.

When the expanded form is checked, `authorize` refuses both: "resolves to a
path under" `/proc`, and "is under" `/home`.

This was measured at the policy level only. The Landlock grant itself was not
exercised.

The decision unit cannot fix this on its own: expansion and symlink
resolution are I/O and stay in Rust (section 4). The fix is to run the
forbidden-path check after expansion, on the path that will actually be
opened. Short of that, a `$`-variable could be refused anywhere but the
start, and a planted link could be refused at open time.

## 3. From here to one declaration

Today one plugin manifest is lowered by hand-written code three times:

1. `registry.rs`'s `write_dropin` writes the systemd drop-in for an
   imperative install;
2. `modules/plugins.nix` renders the drop-in for a declared plugin. It shares
   no code with (1); the `wxEnforced` comment and the two-mirror landmines in
   `CLAUDE.md` exist because of that;
3. at launch, `sandbox::prepare` builds the Landlock `FsPolicy` from the caps,
   and `seccomp::build` builds the filter from tier × jit.

IPE has no lowering at all. The running kernel does not have it compiled in
(the roadmap's *Measured starting point*), so it waits on Phase K0.

The steps below are in dependency order. Each one ends in a gate that
compares a single Exsecutor statement with the code it replaces, the way
this step did.

1. **Decide, for more facts (this step's pattern).** The next facts are all
   pure:
   - `validate`'s tier × jit × trust refusals (wasm with `jit = self`;
     untrusted `jit = self` off the microvm tier);
   - the device-capability grammar, which is a unit-directive injection
     guard;
   - `authorize`'s ceilings and trust order;
   - the `authorize_signature` truth table.
2. **Emit the drop-in.** Write the drop-in text into a buffer the caller
   owns. Certify it byte for byte against `write_dropin` and against the
   Nix-rendered drop-in for the same manifest. The two generators then
   collapse into one checked statement. One question is open: Nix would
   consume emitted text through a build-time derivation, while
   `plugins.nix` renders the declared-plugin drop-in at eval time today.
   `[OPEN]`
3. **Emit the Landlock ruleset as data.** That means (path, access-mask)
   pairs: read-execute for `/nix/store`, read without `EXECUTE` for
   `fs_read`, read-write without `EXECUTE` for `fs_read_write`, and the
   per-plugin state and config directories. Rust keeps the part that touches
   the system: opening each `PathFd` and calling `landlock_restrict_self`.
4. **Emit the seccomp rules as a table keyed by tier × jit.** `seccompiler`
   keeps assembling the BPF. `jit = none` carries more routes than
   `MemoryDenyWriteExecute`: anonymous `PROT_EXEC`, `ptrace` and
   `userfaultfd` (see `docs/plugins-roadmap.md` §4.1). The table is where
   that list stops being implicit.
5. **One declaration.** The declared-plugin submodule and `plugin.toml`
   become one input, rendered to a fixed JSON shape. A host tool built from
   Exsecutor's C emits all three artifacts. The gate is the one Phase K1
   names: on a corpus of declarations, a declaration that grants less must
   produce artifacts that deny more.
   - Until Exsecutor has a checker for over-broad rules (roadmap C.1), this
     holds by construction of the emitter, not as a checked property. The
     gate should say so.
6. **IPE**, once Phase K0 puts a kernel with IPE under it.

## 4. What stays in Rust

Everything that needs the filesystem, the kernel or a parser stays in Rust:

- TOML and JSON parsing (serde);
- capability expansion and canonicalisation (`Manifest::expand`,
  `std::fs::canonicalize`);
- opening each `PathFd`, and the Landlock and seccomp syscalls;
- systemd and `nix` subprocesses, and signature verification;
- the control socket.

The split is deliberate. A decision that cannot read the filesystem cannot
be changed by the filesystem's state between the check and the use; it can
only be given the wrong input. The finding in section 2 is exactly that: the
right decision, given the wrong spelling. So the boundary between the two
halves is an interface to specify, and a gate should test it, as the corpus
does for the lexical half.

## 5. How this ties to Exsecutor's capability atoms

Exsecutor's capability set (spec §4.6) is `Mundus`, `alloc`, `sermo`,
`horologium`, `archivum`, `rete`, `fortuna`, `ambitus`, `Filum`, `machina`
and `Crudum`. A function that declares no row and takes no capability
parameter is pure with respect to ambient state (§4.1 rule 6). That property
is what makes the unit above a policy *decision*: it is a function of its
arguments alone. Upstream checks it by drawing `ambitus` or `archivum`
ambiently and requiring `EXS-E0421`.

The atoms are process-level. They say what an Exsecutor program may touch,
not what a plugin may touch. Two consequences follow:

- **For userspace lowering (steps 1 to 5), no new atom is needed.** The
  compiler is an ordinary host program. Its decision half is capability-free,
  and its I/O half holds `archivum` and `ambitus` like any other tool.
- **The language is not yet the policy language.** The appealing endpoint
  would have a plugin declare an Exsecutor capability row, with the compiler
  lowering `archivum` to a Landlock ruleset and `rete` to Landlock network
  rules or a network namespace. That needs rows parameterised by path and
  port, which the atom set does not have. Kernel-side authority is a further
  spec amendment with new diagnostic codes (roadmap B.4). Both are
  Exsecutor's to design, through its ADR process. `[OPEN]`

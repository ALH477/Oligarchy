# Patches carried against `velocitty`

**Every file here is a commit proposed upstream, byte for byte.** They are
`git format-patch` exports of commits on a branch of valvesky/velocitty, and
they exist so the local fix and the upstream proposal are the *same artifact*
and cannot drift apart.

| patch | upstream | what it does |
|---|---|---|
| `0001-build-add-a-test-step-…` | PR (filed) | `build.zig` declares no `test` step, so none of the 95 `test` blocks in `src/` had ever been run — while upstream's own `AGENTS.md` documents `zig build test`. Adds the step plus `src/test_all.zig`. |
| `0002-src-font-tests-must-skip-loudly-…` | PR (filed) | Five tests open a system font with `catch return`; a bare `return` reports as a **PASS**, so the suite was green while asserting nothing. Routes them through a helper returning `error.SkipZigTest` and printing the path. |

## The rule

> A patch is deleted the day its PR merges and the `velocitty` input is bumped
> past it — not before, and **never edited in place**. To change a patch,
> change the upstream commit and re-export it.

Editing a patch here without moving the upstream commit is how the two silently
diverge, and after that the PR and the thing we actually build are different
software with the same name.

## Why these are patches and the rest are not

`modules/terminal/velocitty.nix` also carries `substituteInPlace --replace-fail`
calls — for `fc-match`, for `/usr/{include,lib}`, and for the test font paths.
Those are **not** candidates for this directory, and the dividing line is forced
rather than chosen: they interpolate *this machine's store paths*. A patch
carrying `/nix/store/…-fontconfig-2.17.1-bin/bin/fc-match` is unmergeable by
construction, and would need regenerating on every nixpkgs bump.

So: **a fix that can be an upstream commit is shaped like one and lives here; a
fix that can only ever be a Nix pin stays a `--replace-fail` one-liner**, where
it also gives a better error (it names the file and the exact pattern) than a
rejected hunk would.

## What is *not* patched, and will not be

`tests/` — the golden PNGs, the VT fixtures, the render harness — is **dead
code that does not compile**. Every file in it imports a module `ZT` that
`build.zig` never declares and `src/` never exports; there is no `Engine`
anywhere in the tree, and `build.zig.zon`'s `.paths` excludes `tests/`
entirely. It is inherited from the author's earlier project (the README calls
velocitty "a streamlined version of my GPU-accelerated terminal multiplexer
VT") and was never adapted.

Wiring it would mean reconstructing an API upstream deleted and then blessing
goldens against our own reconstruction — a self-referential gate wearing a
fidelity gate's name. Reported upstream as an issue instead; the decision about
whether `Engine` comes back is the maintainer's, not ours.

Consequence, stated plainly so nobody assumes otherwise: **pixel-exact glyph
rasterisation is unmeasured.** `.#velocitty-tests` measures that a live
windowed velocitty draws *something* rather than a blank rectangle, which is a
weaker claim, and it says so.

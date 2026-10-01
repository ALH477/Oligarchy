**Title:** `build: add a test step, and stop the font tests passing silently`

---

Two commits. The first makes `zig build test` exist; the second makes what it
runs honest. Neither changes any runtime behaviour.

### 1. `build.zig` has no `test` step

`AGENTS.md` (Rendering tests) documents:

> Bless dumps and PNGs with `ZT_UPDATE_GOLDEN=1 zig build test`.
> Dirty vs full: `tests/render.zig` (32 iters). Long run: `zig build fuzz-render -- 10000`.

Neither step exists:

```
$ zig build test
error: no step named 'test'

  access the help menu with 'zig build -h'
```

`build.zig` declares `run`, `bench`, `release`, `package` and `install-usr`.
So none of the **95 `test` blocks in `src/`** have ever been run by the build
system — `vt.zig` alone has 32, `scheme.zig` 10, `kitty.zig` 9, `key.zig` 7,
`csi.zig` 6.

This commit adds a `test` step rooted at a new `src/test_all.zig`. Rooted there
rather than at `src/main.zig` deliberately: Zig only analyses files that are
actually referenced, so rooting at `main.zig` would silently collect a subset
and still report success.

The test module does **not** link X11 — `test_all.zig` pulls in neither
`platform/linux.zig` nor `main.zig` — so the suite runs in a container or CI
image with no X development libraries present.

```
$ zig build test --summary all
Build Summary: 3/3 steps succeeded; 96/96 tests passed
test success
+- run test 96 pass (96 total) 48ms MaxRSS:8M
```

*(It does not touch `tests/`. That tree has a separate problem — see the issue
I filed alongside this.)*

### 2. Five font tests pass without testing anything

```zig
const file = std.Io.Dir.openFileAbsolute(io, "/usr/share/fonts/liberation/LiberationMono-Regular.ttf", .{}) catch return;
```

A bare `return` from a test body reports as a **PASS**. So on any machine
without that exact path the test is green while asserting nothing — including
an Arch box that simply does not have `ttf-liberation` or
`ttf-iosevka-term-nerd` installed.

Affected:

| file | test |
|---|---|
| `src/type.zig` | `glyph and layout from system font` |
| `src/type.zig` | `color emoji glyph` |
| `src/type.zig` | `bold face is a different glyph` |
| `src/type/truetype.zig` | `rasterize system font` |
| `src/type/cbdt.zig` | `noto color emoji grin` |

This routes them through a small helper that returns `error.SkipZigTest` and
prints the path. The runner counts skips separately, so the result is honest
either way, and a failure *after* a successful open stays a real error rather
than becoming a skip.

```
before:  96/96 tests passed           (5 of them asserting nothing)
after:   91 pass, 5 skip (96 total)   (each skip printed by path)
```

On a machine that *does* have the fonts, all 96 pass.

### How this was found

Packaging velocitty for NixOS, where none of those `/usr/share/fonts` paths
exist. Happy to split this into two PRs if you'd rather take them separately.

**Title:** `tests/ imports a module "ZT" that build.zig never declares`

---

`tests/` cannot compile against `src/`, and I do not think it can be fixed from
outside the project — hence an issue rather than a patch.

Every file in `tests/` begins:

```zig
const zt = @import("ZT");
```

There is no `ZT` module declared in `build.zig`, and nothing in `src/` exports
that surface. Taking the symbols the tests actually use:

| tests use | in `src/`? |
|---|---|
| `zt.Draw.Frame` | yes (`src/draw.zig`) |
| `zt.Type.Context` / `.Atlas` / `.EastAsian` | yes (`src/type.zig`, `src/type/…`) |
| `zt.Term.Screen` (`.init(gpa, cols, rows)`, `.feed(runs, src)`) | **no** — nearest is `vt.VtState`, with a different signature |
| `zt.Runs.split`, `zt.Preparse.scan`, `zt.Preparse.Line` | **no** — run splitting is a method, `CircBuffer.splitIntoRuns` |
| `zt.Engine` (owns cols/rows/cell_w/cell_h/hz, `ingest()`, `refresh()`, `.frame`) | **no — nothing named `Engine` exists anywhere in `src/`** |

`build.zig.zon`'s `.paths` also excludes `tests/`, so the tree is not packaged.

Combined with the missing `test` step (see the PR I opened), this means the
golden PNGs in `tests/golden/`, the VT fixtures in `tests/vt/`, and the render
harness are all currently dead code. The README describes velocitty as "a
streamlined version of my GPU-accelerated terminal multiplexer VT", so my guess
is these came across from that project and the `Engine`/`Term`/`Runs` layer was
flattened away afterwards.

**Do you want them back?** If you tell me the intended shape of `Engine` — or
that you would rather the tests be rewritten against `VtState` and `Draw.Frame`
as they exist today — I am happy to do the port and send it. I did not want to
invent an API and then bless goldens against my own invention, which would look
like a passing test suite while proving nothing.

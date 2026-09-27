**Title:** `zig build release ships a binary with a relative RPATH entry`

---

`readelf`/`patchelf` on an unmodified build:

```
$ patchelf --print-rpath zig-out/bin/velocitty
.zig-cache/o/bbd269fa5e5dfaa6e3094a391b55fb76
```

That is the emitted-binary directory of the `libxkbcommon` link stub that
`addX11LinkStub` always builds (`build.zig`, `addLinuxX11`), leaking into the
final executable's `DT_RUNPATH` as a **relative** entry.

A relative RPATH is resolved **against the process's current working
directory**, not against the binary's location. So a velocitty started from any
directory an attacker can write to will look for `libxkbcommon.so.0` — and
`libX11.so.6`, `libXi.so.6` — in `./.zig-cache/o/bbd269…/` first.

This also ends up in the tarballs `zig build package` produces, so it reaches
anyone installing from a release artifact rather than building in place.

It is dead weight even ignoring that: the path is a build-time cache directory
that does not exist on the installed system.

Reproduced on x86_64-linux with zig 0.16.0 at `1c560e1`. I have not sent a
patch because the right fix depends on whether you want the stub directory on
the *link* path only (it is only needed at link time) or want the rpath
stripped afterwards, and that is your call.

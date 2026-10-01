**Title:** `a release build that finds no font renders nothing and says nothing`

---

When every font lookup fails, `src/main.zig` does:

```zig
} else |_| {
    Debug.log("no fonts found; drawing without glyphs\n", .{});
```

and `src/debug.zig` is:

```zig
pub fn log(comptime fmt: []const u8, args: anytype) void {
    if (builtin.mode == .Debug) {
        std.log.debug(fmt, args);
    }
}
```

`Debug` — so the message is **compiled out of every Release build**, which is
the mode both `zig build release` and `zig build install-usr` use.

The result is that a release velocitty on a machine with no usable font opens
its window, spawns its `-e` child, renders **nothing at all**, and exits 0 —
printing no diagnostic of any kind. I measured this: stdout and stderr are
completely empty.

This is not distribution-specific. The fallbacks in `loadFonts` are
`/usr/share/fonts/iosevka-term/…`, `/usr/share/fonts/liberation/…`,
`/usr/share/fonts/TTF/DejaVuSansMono.ttf`, `/usr/share/fonts/noto/…`, so an
Arch box without `ttf-liberation` and `ttf-iosevka-term-nerd` installed — and
with `fc-match` returning something velocitty cannot open — gets a black
rectangle with no explanation.

**Ask: route that one message through `std.log.err` so it survives Release.**
One line. It turns an unexplainable blank window into a one-line diagnostic.

(I am deliberately not asking for configurable font paths in the same breath —
that is a bigger design question and a separate conversation.)

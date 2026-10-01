# `custom.terminal` — the user terminal and the system terminal

Two terminals, split by job:

| role | what it is | what opens it |
|---|---|---|
| **user** | kitty, unchanged | `$mod+Return`, the scratchpads, `TERMINAL`, Hyprland's `$terminal`, the IceWM *Terminal* entry, and now the XDG default |
| **system** | velocitty, when `custom.terminal.velocitty.enable` is on | the GUI path that runs `sudo nixos-rebuild switch`, the security sweeps, the repo update checks |

Before this module there was no terminal abstraction at all. "kitty" was
declared independently in three places and repeated in ~20 hardcoded literals
across Nix, bash, Python and an IceWM menu DSL. All three now derive from
`custom.terminal.user.package`.

## The wrapper

```
oligarchy-system-term [--app-id NAME] [--title TEXT] [--dir DIR] [--hold] [--] CMD [ARG...]
```

installed at `/run/current-system/sw/bin/oligarchy-system-term`. The fixed path
is the point: bash, Nix interpolation, Python and an IceWM menu can all name
the same thing, and it is the only form reachable from
`modules/hypr-controller/hypr_bridge.py`, a daemon with neither `$TERMINAL` nor
a login `PATH`.

The flag *names* are `xdg-terminal-exec`'s, so anyone who knows the freedesktop
spec already knows this wrapper. `--class` remains an accepted alias.

**`--hold` is implemented here, in shell, and has to be.** Two terminals, two
different silent failures:

* velocitty's argument parser **silently ignores unknown flags**, so
  `velocitty --hold -e cmd` drops it with no diagnostic and the window vanishes
  on the error you wanted to read.
* `xdg-terminal-exec` would not help either: it honours `--hold` only via an
  `X-TerminalArgHold=` key in the desktop entry, and when the key is missing it
  reports that through a `debug` function that is a no-op unless `XTE__DEBUG`
  is set. `kitty.desktop` declares the key; **velocitty's entry does not.**

`.#terminal-contract` asserts that asymmetry, and `.#velocitty`'s
`installCheckPhase` asserts velocitty still declares no `X-TerminalArgHold`, so
neither claim can rot.

## XDG registration, and why it is additive rather than an integration

`custom.terminal.xdg.enable` (on from `configuration.nix`) drives nixpkgs' own
`xdg.terminal-exec` module, writing `/etc/xdg/xdg-terminals.list` with the user
terminal's desktop id. Nothing in this tree did that before, **and the default
answer was wrong**:

```
$ XDG_CONFIG_HOME=/nonexistent xdg-terminal-exec --print-id
kitty-open.desktop          # before
kitty.desktop               # after
```

`kitty-open.desktop` is kitty's URL launcher (`Exec=kitty +open %U`,
`NoDisplay=true`); it carries a `TerminalEmulator` category but no
`X-TerminalArgExec=`, so it qualified only under the utility's compat mode.
Anything asking this desktop for a terminal got `kitty +open %U -e <cmd>`.

**The spec cannot express "two terminals for two purposes", so this names the
interactive one and nothing else.** The data model is singular: there is no
purpose dimension in `xdg-terminals.list`, in the `X-TerminalArg*` keys, or in
the CLI. The one lever with roughly the right shape —
`${desktop}-xdg-terminals.list`, matched against `$XDG_CURRENT_DESKTOP` — is
**session**-scoped, so two callers inside one Hyprland session cannot differ,
and overriding that variable misroutes xdg-desktop-portal, which
`configuration.nix` makes system-authoritative. Overriding `XDG_CONFIG_HOME`
instead leaks into the admin shell (velocitty reads
`$XDG_CONFIG_HOME/velocitty/config.toml`); overriding `XDG_CONFIG_DIRS` leaks
*and loses*, because `$XDG_CONFIG_HOME/xdg-terminals.list` is read first — a
user dotfile could then silently retarget the window a `sudo nixos-rebuild
switch` draws in.

So the wrapper stays. These are two orthogonal mechanisms, not one built on the
other, and that is a conclusion rather than a hedge.

**Velocitty's own `.desktop` is deliberately not installed.** It carries
`Categories=System;TerminalEmulator;` and a full `X-TerminalArg*` set, which
makes it a live candidate for any chooser — and kitty was only winning that
scan because `k` sorts before `v`. The package moves it to
`share/velocitty/` rather than deleting it, so `installCheckPhase` can still
assert that `-e` is what upstream advertises; `rmdir` (not `rm -rf`) removes
the now-empty `share/applications`, so it fails loudly if upstream ever ships a
second entry.

## Landmines

### Font discovery fails silently, and in a release build says nothing at all

`src/main.zig` resolves its font family by spawning **`fc-match` off `PATH`**.
When that misses, the fallbacks are hardcoded Arch paths that do not exist on
NixOS. With both legs dead, velocitty opens its window, spawns its `-e` child,
renders nothing, and exits 0.

There is no log line to catch it by either: the `"no fonts found; drawing
without glyphs"` message goes through `Debug.log`, which is
`if (builtin.mode == .Debug)` — **compiled out of the ReleaseFast build we
ship**. Grepping stderr for it is a vacuous gate. Measured, not assumed: a
font-starved release velocitty prints nothing whatsoever.

So `velocitty.nix` burns the absolute store path to `fc-match` into the source.
Deliberately **not** a `makeWrapper --prefix PATH`: velocitty hands its own
environ to the shell it spawns, so a `PATH` prefix would leak into every
command the user then runs in that window.

`hyprctl monitors -j` is left a bare `PATH` lookup on purpose — a soft
refresh-rate query with a 60 Hz fallback, and pinning it would drag Hyprland
into a terminal's closure.

### `libxkbcommon` is linked against a stub that is never installed

`build.zig`'s `addX11LinkStub` **always** builds a fake `libxkbcommon.so.0`,
because the host library needs a newer glibc than zig's. The shipped binary
therefore carries `DT_NEEDED libxkbcommon.so.0` with nothing resolving it but
the RPATH.

The rpath work is in `postFixup`, not `postInstall`, because nixpkgs' own fixup
runs `patchelf --shrink-rpath` and discards anything added earlier. It corrects
two things at once: zig leaks a **relative** entry (`.zig-cache/o/<hash>`) that
resolves against the process CWD — dead weight and a library-injection surface
— and resolution would otherwise run through the build-time `symlinkJoin`,
dragging the X11 *dev* outputs into the runtime closure.

### `build.zig` hardcodes `/usr/include` and `/usr/lib`, and consults no pkg-config

Every `linkSystemLibrary` passes `use_pkg_config = .no`, so adding a
`pkg-config` build input does nothing. `postPatch` redirects both FHS paths at
one `symlinkJoin` of the X11 dev and lib outputs plus `xorgproto`.

### Other

* **No `--help`, no `--version`.** There is no cheap smoke test; the gate has
  to start a real X server and a real PTY child.
* **X11 only.** No Wayland backend, so under Hyprland it runs through XWayland;
  an assertion refuses the combination when XWayland is off, because the window
  would simply never appear. Under the IceWM fallback session there is no
  XWayland layer at all.
* **The config file is unmanaged.** Velocitty reads
  `$XDG_CONFIG_HOME/velocitty/config.toml` and nothing here writes it, so the
  upstream note about it being "overwritten by omarchy color scheme" does not
  apply. A per-theme palette generator, matching the one
  `home/terminal/kitty.nix` already has for kitty, is the obvious follow-up.
* **Swallow is deliberately not extended.** `swallow_regex` still lists only
  `kitty|foot`. A long-running admin window should not be hidden behind
  something it spawned. Its absence is a decision, not an oversight.
* **`modules/icewm.nix` is a dead duplicate** of the live menu in
  `configuration.nix` — nothing imports it, so it was left alone.

## Tests, and what is still unmeasured

`velocitty.nix` carries two patches (`patches/`), each byte-for-byte a commit
proposed upstream. They add the `test` step `build.zig` never had — so the
**95 `test` blocks in `src/` that had never been run** now run on every
build — and stop five font tests passing silently when the font is absent.
`checkPhase` refuses two different kinds of nothing: a suite that did not run,
and a suite that ran but skipped.

**Upstream's `tests/` tree is NOT wired, and cannot be.** Every file in it
imports a module `ZT` that `build.zig` never declares and `src/` never
exports — there is no `Engine` anywhere in the tree, and `build.zig.zon`
excludes `tests/` from `.paths`. It is inherited from the author's earlier
project. Wiring it would mean reconstructing a deleted API and then blessing
its own goldens against our reconstruction.

**So pixel-exact glyph rasterisation is unmeasured**, and will stay that way
until upstream decides what `Engine` should be (reported; see `upstream/`).
`.#velocitty-tests` measures the weaker, honest claim instead: that a live,
windowed velocitty draws *something* rather than a blank rectangle — 166
distinct pixel values with a font versus 4 without, with an adversary leg that
starves it on purpose so the measurement is proven able to fail.

Also unmeasured: keyboard and XInput2 input; the `hyprctl` scale query; the
TOML config; the kitty graphics protocol; XWayland itself, since the gate uses
a bare X server rather than a Hyprland session; and the real-session font path,
because the gate's `fc-match` reads a generated `fonts.conf` rather than
NixOS's `/etc/fonts`. The manual smoke below is the only thing covering that
last one.

## Gates

```bash
nix build .#velocitty          # 96 unit tests, then 9 installCheck assertions
nix build .#velocitty-tests    # 6 checks: a real X server, a real PTY child, real glyphs
nix build .#terminal-contract  # velocitty is the system terminal; kitty is still the user default
```

### The anti-vacuity leg must not depend on entry order

`.#terminal-contract` runs the real `xdg-terminal-exec` against a throwaway
`XDG_DATA_HOME` holding two entries: `kitty.desktop` and a copy of it named
`aaa-decoy.desktop`. Proving the *registration* decided the answer needs an
adversary leg, and the obvious one — delete the list, require the answer to
change — is **unsound**.

`xdg-terminal-exec` enumerates candidates with `find -L` and sorts them
nowhere (grep the script: there is no `sort`), prepending each id so the entry
`readdir` yields *last* wins. Readdir order for two names in one directory is
not a property of their names: on ext4 it follows the per-filesystem directory
hash seed, which is random per filesystem, and on tmpfs it follows creation
order. Measured, same two files, same resolver:

| filesystem | created | no list | list=kitty | list=decoy |
|---|---|---|---|---|
| tmpfs | kitty first | `kitty.desktop` | `kitty.desktop` | `aaa-decoy.desktop` |
| tmpfs | decoy first | `aaa-decoy.desktop` | `kitty.desktop` | `aaa-decoy.desktop` |
| ext4 | either | `aaa-decoy.desktop` | `kitty.desktop` | `aaa-decoy.desktop` |

The no-list column is a coin flip decided by whose disk ran the test — which is
exactly how that leg came to be green on the maintainer's machine and red on a
GitHub runner **from a byte-identical derivation**. The list columns do not
move.

So the leg flips the list's *contents* instead and requires the answer to
follow it. That keeps the anti-vacuity property the deleted leg was reaching
for: if the list were ignored, both legs would return the same readdir-chosen
id, so one of them would fail — and it stays sound on any filesystem.

```bash
velocitty -e sh -c 'echo hello; sleep 3'     # fonts against the REAL /etc/fonts
oligarchy-system-term --hold -- false        # --hold survives a non-zero exit
xdg-terminal-exec --print-id                 # must print kitty.desktop
```

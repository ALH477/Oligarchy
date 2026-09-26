# modules/screensaver — `custom.screensaver`

An idle screensaver whose engine is written in **Exsecutor**, the
capability-typed systems language at `github:ALH477/exsecutor`. The engine
is `somnium` (`examples/somnium/` there, design in `docs/design/somnium.md`
there): three effects, a sine **plasma**, a heat-diffusion fire (**ignis**)
and Conway's Life coloured by age (**vita**), compiled by `exsc` and
assembled by `fasmg` into a freestanding binary with no libc.

```nix
custom.screensaver = {
  enable = true;
  # somnia = [ "ignis" ];   # one effect, no cycling
  # period = 60;            # seconds per effect when cycling
  # fps = 20;
  # timeout = 420;          # idle seconds; must be < hypridle's lock (600)
  # pixelated = true;       # nearest-neighbour upscale of the 160x100 frame
};
```

Off by default. Disabled, it adds nothing and never fetches the `exsecutor`
input.

## How it fits together

```
hypridle ── timeout ──> systemctl --user start oligarchy-screensaver.service
                          └─ oligarchy-screensaver (script.nix)
                               loop: request (17 bytes) | somnium ──┐
                                                                    ├─ raw rgb24 160x100
                               mpv --demuxer=rawvideo --fs ... - <──┘
hypridle ── on-resume ─> systemctl --user stop  (kills the cgroup: somnium + mpv)
hypridle ── 660 s ─────> dpms off; stop the screensaver
```

- **The engine has no clock and no entropy.** Time is the frame index;
  randomness is a 32-bit seed in the request. The host picks the seed
  (`$SRANDOM`, fresh per effect), so the screen differs night to night, but
  the same request always renders the same bytes. That is what lets the
  gate hold the binary to exsecutor's golden files.
- **Why 160x100.** Exsecutor's runtime writes arbitrary bytes one `write(2)`
  per byte (`Scriptor.scribe_octeto`), so a frame costs 48,000 syscalls.
  The frame is small on purpose and 16:10 like the Framework 16 panel; mpv
  scales it up, nearest-neighbour by default.
- **mpv is told not to inhibit idle** (`--stop-screensaver=no`). By
  default mpv holds an idle inhibitor while it plays, hypridle honours
  inhibitors, and the lock and DPMS-off listeners would never fire. That
  would be a screensaver that keeps the session unlocked. The gate asserts
  the flag.
- **It runs under the lock until DPMS-off**, and stopping it *at* the lock
  was rejected on purpose: that would uncover the desktop for as long as
  hyprlock takes to raise its surface. Resume stops it either way.
- **The dim rung (300 s, backlit hosts) comes first**, so with the default
  timeout the screensaver plays at the dimmed brightness. Set `timeout`
  below 300 if you want it at full brightness first.
- **The producer loop exits when mpv does.** somnium dies of SIGPIPE at its
  next write, and `|| return 0` ends the loop. Without that, the loop would
  respawn somnium into a closed pipe as fast as fork allows. The gate would
  hang on exactly that failure.

## Gate

```bash
nix build .#screensaver-tests
```

No KVM, no compositor. It checks four things:

1. The engine, as exsecutor's flake builds it, renders the four effect
   fixtures byte-identical to exsecutor's goldens and refuses the four bad
   requests with exit 1 and no output.
2. `script.nix`'s bash request encoder is byte-identical to exsecutor's
   fixture requests.
3. The real pipeline (real argv plus `--vo=null`) decodes as
   `160x100 rgb24`, crosses all three effects, and exits when mpv does.
4. The idle flag is present.

The gate also reports frames per second per effect as a measurement, not an
assertion. It is the number to pick `fps` against.

**Not measured by the gate:** anything a compositor does. That covers the
window rules, which monitor gets the fullscreen window, and hypridle
actually firing the listener. Those need a live Hyprland session.

## Evidence, stated plainly

This module and the exsecutor side were written in an environment with no
`nix` and no `fasmg`. What ran there:

- `nixpkgs-fmt --check` (1.3.0) on every changed `.nix` file.
- The script's bash, rendered from the template by hand. The request
  encoder matched all five fixture requests byte for byte. The produce and
  view loop was run against the exsecutor oracle standing in for somnium
  and a fake viewer that takes N frames and quits: the loop exited, the
  effects rotated, and no process was left behind.

What has **not** run: `nix build` of anything here, the somnium binary
itself, mpv on this stream, the gate. `.#screensaver-tests` is the first
real measurement.

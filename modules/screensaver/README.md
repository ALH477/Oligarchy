# modules/screensaver — `custom.screensaver`

An idle screensaver whose engine is written in **Exsecutor**, the
capability-typed systems language at `github:ALH477/exsecutor`. The engine
is `somnium` (`examples/somnium/` there, design in `docs/design/somnium.md`
there). It has nine effects:

| name | what |
|---|---|
| `titulus` | the title card: rain flies together into **OLIGARCHY**, then *EXSECVTOR PINXIT* ("Exsecutor painted it") and *PVNCTIM CECINIT* ("Punctim sang it") type in beneath |
| `signum` | the Exsecutor logo turning in the starfield, drawn by **Exsecutor's own 3D engine** (`examples/signaculum/forma.exsc`, unmodified) |
| `pluvia` | digital rain |
| `stellae` | warp starfield |
| `cuniculus` | the demoscene XOR tunnel, in the logo's crimson and navy |
| `abyssus` | Mandelbrot deep zoom into the Seahorse Valley (f64) |
| `plasma` | sine plasma |
| `ignis` | fire |
| `vita` | Conway's Life coloured by age |

The default order lets the rain resolve into the title and the stars lead
into the logo.

```nix
custom.screensaver = {
  enable = true;
  # somnia = [ "titulus" "signum" ];  # the Oligarchy/Exsecutor pair only
  # period = 45;            # seconds per effect when cycling
  # fps = 20;
  # timeout = 420;          # idle seconds; must be < hypridle's lock (600)
  # pixelated = true;       # nearest-neighbour upscale of the 160x100 frame
  # backend = "c";          # "c" (fast, default) or "reference" (freestanding)
  # cflags = [ "-march=x86-64-v3" "-mtune=znver4" ];  # default on AMD hosts
};
```

Off by default. Disabled, it adds nothing and never fetches the `exsecutor`
input.

## Performance: two builds of one source, and the GPU

- **`backend = "c"` (default).** exsc's C backend, compiled with `cflags`
  and a host (`examples/somnium/hospes.c`) that buffers output to one
  frame, so each frame is **one** `write(2)`. It is portable C11: `cflags =
  [ ]` runs on any x86-64. The default AVX2-class `-march=x86-64-v3` with
  `-mtune=znver4` targets the Framework 16's Ryzen 7040. Contraction is
  pinned off, so an FMA-capable `-march` cannot change a float effect's
  bits.
- **`backend = "reference"`.** The freestanding fasmg build: no libc, and
  a syscall surface audited to read/write/exit_group. It writes one byte
  per `write(2)`, which is 48,000 system calls a frame, so it is slower. It
  is the build Exsecutor's purity claims are about.
- **Both builds write the same bytes.** The gate holds each one to
  exsecutor's golden frames and prints each one's frames per second per
  effect.
- **The GPU's share is presentation.** mpv scales the 160x100 frame and
  presents it with its default `gpu-next` output, on the 780M iGPU the
  compositor already renders on (`DRI_PRIME` is unset, per
  `docs/dgpu-steam-forcing.md`, so there is no cross-device copy).
  Exsecutor cannot yet put a parallel loop on an AMD GPU: its device path
  runs a whole program as one workitem, a correctness certificate rather
  than a speed-up. `docs/design/somnium.md` §6 in the exsecutor repo says
  exactly which loops are ready to declare `quisque` when that changes.

## How it fits together

```
hypridle ── timeout ──> systemctl --user start oligarchy-screensaver.service
                          └─ oligarchy-screensaver (script.nix)
                               loop: request (+ 3D model) | somnium ┐
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
- **Why 160x100.** Exsecutor's reference runtime writes arbitrary bytes one
  `write(2)` per byte, and the 3D effect renders 512x512 per frame. So the
  frame is small on purpose, and 16:10 like the Framework 16 panel. mpv
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

1. **Both** builds render all eleven effect fixtures byte-identical to
   exsecutor's goldens, and refuse all six bad requests with exit 1 and no
   output.
2. The bash request encoder is byte-identical to exsecutor's fixture
   requests, and the shipped 3D model is the one the goldens were rendered
   from.
3. The real pipeline (real argv plus `--vo=null`) decodes as
   `160x100 rgb24`, and exits when mpv does. It runs twice: across three
   effects, and on the logo alone, which exercises the model path.
4. The idle flag is present.

It also reports frames per second per effect for each build, as a
measurement rather than an assertion. That is the number to pick `fps` and
`backend` against.

**Not measured by the gate:** anything a compositor or GPU does. That covers
the window rules, which monitor gets the fullscreen window, mpv's GPU
scaling, and hypridle actually firing the listener. Those need a live
Hyprland session.

## Evidence, stated plainly

This module and the exsecutor side were written in an environment with no
`nix` and no `fasmg`. What ran there:

- `nixpkgs-fmt --check` (1.3.0) on every changed `.nix` file.
- The script's bash, rendered from the template by hand:
  - the request encoder matched exsecutor's fixture requests byte for byte;
  - the produce and view loop ran against the exsecutor oracle standing in
    for somnium and a fake viewer, across rain, the 3D logo (model path)
    and the zoom. The loop exited, and no process was left behind.
- On the exsecutor side:
  - the oracle's copy of the 3D engine is byte-identical to that engine's
    certified 512x512 render;
  - the C host was exercised with a stand-in program: one `write(2)` per
    frame, SIGPIPE on close.

Since then, the **reference build has been built and run** (for the README
animations, `assets/screensaver-*.gif`):

- `nix build github:ALH477/exsecutor/<the rev in flake.lock>#somnium` succeeds,
  producing the freestanding binary and `share/somnium/signaculum_mesh.bin`.
- Driven straight over stdin with the 17-byte request this module's
  `script.nix` encodes, it renders all nine somnia. All **17** of exsecutor's
  `tests/programs/somnium_*` fixtures pass against that binary: 11 render
  `expected.out` byte-identical (including `abyssus`'s `f64` zoom and the
  `signum` model path), and 6 malformed requests are refused with exit 1 and
  zero bytes.

So the engine is no longer `[UNTESTED]`: it compiles, it runs, and it agrees
with the oracle that wrote the goldens.

What still has **not** run: the `c` backend build, `mpv` on this stream, and
the gate itself. `.#screensaver-tests` remains the first measurement of the
*pipeline* — and of the two backends agreeing with each other, which the run
above does not test.

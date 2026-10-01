# `custom.gamepadBluetooth` — Bluetooth Xbox pads

Two jobs that happen to live in one module because they are the two halves of
one user-visible outcome, "the pad works":

1. **Finish the bond.** A BLE Xbox pad arrives `Connected=yes Paired=no`, and
   HID-over-GATT does not come up until something calls `Pair()`. A root
   oneshot does that, for gamepads only.
2. **Make the pad reach games.** That is almost entirely a udev problem, and it
   is the part nixpkgs leaves undone.

Opt-in. `configuration.nix` defaults it to `custom.steam.enable`, so a fresh
clone with Steam off adds nothing at all and the ISO needs no `mkForce`.

```nix
custom.gamepadBluetooth = {
  enable = true;
  # xpadneoQuirks = { "74:C4:12:ED:8F:76" = 512; };  # per-MAC, machine-specific
  # tuneLeLatency = false;                           # upstream's [LE] intervals
};
```

## The bonding half

`hog_finish_bond.py` shells out to `bluetoothctl` — no D-Bus library — and
`classify()` is the whole security surface. It pairs a device only when all of
these hold: not `Blocked`, already `Connected`, GAP appearance exactly `0x03c4`
(gamepad), and the HID UUID `00001812` present. **Names are ignored**, which is
deliberate and tested: a keyboard calling itself "Xbox" is appearance `0x03c1`
and must never be paired. `Trust()` happens only after re-reading `info` and
confirming `Paired=yes`, never off the `pair` exit code, because BlueZ can
finish a bond after the CLI is killed at its timeout.

What it does **not** do, all deliberately: it sets no
`JustWorksRepairing=always` (a re-bond/MITM hole), registers no
`NoInputNoOutput` agent, never trusts an unpaired device, and never makes the
adapter discoverable. Residual risk, stated rather than hidden: a BLE
advertiser spoofing appearance `0x03c4` plus the HID UUID can obtain a
Just-Works pair — the same class of exposure as a user clicking Pair on a fake
gamepad.

A udev `SYSTEMD_WANTS` tag starts the oneshot on bluetooth device add. `RUN+=`
would block the udev daemon, hence the indirection.

## Landmines

### nixpkgs' `xpadneo` package installs the kernel module and nothing else

This is the one that cost real time, because every symptom pointed away from
it. The pad bonded. The driver bound. The kernel log was *immaculate*:

```
xpadneo 0005:045E:0B13.0009: BLE firmware version 5.09, please upgrade for better stability
xpadneo 0005:045E:0B13.0009: pretending XB1S Windows wireless mode (changed PID from 0x0B13 to 0x028E)
xpadneo 0005:045E:0B13.0009: report descriptor size: 283 bytes
xpadneo 0005:045E:0B13.0009: fixing up Rx axis / Ry axis / Z axis / Rz axis
xpadneo 0005:045E:0B13.0009: fixing up button mapping
xpadneo 0005:045E:0B13.0009: enabling compliance with Linux Gamepad Specification
input: Xbox Wireless Controller as /devices/virtual/misc/uhid/0005:045E:0B13.0009/input/input24
xpadneo 0005:045E:0B13.0009: testing weak motor / strong motor / trigger motors
xpadneo 0005:045E:0B13.0009: Xbox Wireless Controller [78:86:2e:ba:73:6e] connected
```

Every descriptor fixup applied, Linux Gamepad Specification compliance on, an
evdev node created, and the force-feedback connect test *physically firing* —
so data flowed in both directions. And no input reached any game.

The cause is packaging, not code. nixpkgs' derivation sets `setSourceRoot` to
`hid-xpadneo/src`, one directory below upstream's `etc-udev-rules.d/`, and its
`installTargets` is `modules_install` alone. The output tree is one file,
`hid-xpadneo.ko.xz`, and the derivation contains no `udev` string anywhere.
Upstream installs its rules from a `dkms.post_install` hook, which a Nix build
never runs, and the NixOS module adds no `services.udev.packages` either — on
stable or on master. So both rules were simply absent:

| rule | what it does |
|---|---|
| `60-xpadneo.rules` | rebinds the pad off `hid-generic` onto xpadneo, then tags the **input** node `uaccess`, `MODE=0664`, `LIBINPUT_IGNORE_DEVICE=1` |
| `70-xpadneo-disable-hidraw.rules` | sets the **hidraw** node `MODE:="0000"` and `TAG-="uaccess"` |

The second is the one that matters here. Steam's own `60-steam-input.rules`
grants the hidraw node to the session while the pad is still bound to
`hid-generic`. With nothing to take that back, SDL's HIDAPI Xbox driver —
present in the SDL3 Steam ships — claims the pad through the **raw** node in
preference to xpadneo's translated evdev stream, and reads HID-over-GATT
reports it cannot interpret. Steam's own log names it: `Controller using HIDAPI
driver, vid=0x045e, pid=0x028e`, then `Controller device closed after hid_read
failure`.

**Never "fix" this by granting the pad's hidraw node `uaccess`.** That is the
exact inverse of the fix and makes the bug permanent. The rules are installed
from the `xpadneo-src` input's own tree so they cannot drift from the driver,
and the derivation `test -f`s both: an upstream layout change fails the build
instead of quietly installing less, which is the failure mode being fixed.

### `hardware.xpadneo.enable` is deliberately not used

It hardcodes `config.boot.kernelPackages.xpadneo`, which nixos-25.11 pins at
0.9.7, whose rules trigger on `ACTION=="add"`. Upstream 0.10 widened both to
`ACTION!="remove"`, and under **systemd 258** — what this host runs — the
narrow form is reported to let the first post-boot connection work while
*reconnects* fall back to `/dev/hidraw*`. Shipping 0.9.7's rules would be a fix
that works exactly once.

So the driver is built from the tag-pinned `xpadneo-src` input and that
module's three config lines are inlined here. Nothing is lost: its whole body
is `boot.extraModulePackages`, `boot.kernelModules`, and a `disable_ertm`
modprobe line gated on `kernel < 5.12` that no kernel this repo supports can
satisfy.

Delete the override and go back to `config.boot.kernelPackages.xpadneo` once
nixpkgs stable ships ≥ 0.10.4 **with the udev rules packaged** — the version
alone is not enough. The rules are the point.

### `uhid` must be loaded, and for firmware 5.x it is mandatory

BlueZ's HID-over-GATT instantiates the pad through `uhid`. Without it, `Pair`
and `Trust` both succeed and `/dev/input/js*` never appears. Upstream
documents it as required specifically for controller firmware 5.x and later,
which these pads are.

### `quirks=MAC:N` replaces, it does not OR

The parser does one `kstrtou32` and writes straight into `devdata->quirks`,
discarding whatever was there. Two consequences, and the second is unresolved:

1. The value must be complete. There is no "add 512 to the defaults".
2. `xpadneo_report_fixup` can itself set bit 16 (*use Linux button mappings*)
   from a report-descriptor byte match, and it runs **before** the override is
   applied. Bit 16 is not cosmetic: it is what makes `xpadneo_raw_event` repack
   the dpad and button bits into the Linux gamepad layout. So writing `512`
   clears bit 16 if the fixup had set it — and the un-overridden boot did
   report `0x57`, which contains it.

Whether these pads need bit 16 is **untested**; it needs the hardware. The
experiment, in order, is `512` (current), then `528` (`512|16`), then no
override at all, checking `evtest` each time. If `528` is what works, record
why here — do not just change the number.

### 512 is narrower than `modinfo` makes it sound

`modinfo` says *apply no heuristics = 512*, and upstream's `quirks.c` gates
exactly **one** heuristic on that bit: the disambiguation that fires when a
descriptor is 283 bytes (as these pads' are) and decides from a secondary
name/MAC-OUI check whether the device is a GameSir Nova clone. The driver's
built-in per-device quirk table, which matches on device name and MAC OUI,
runs regardless. It stops one misdetection; it does not stop guessing.

### The Xbox-360 identity is not the bug

xpadneo unconditionally rewrites `hdev->product` to `0x028E` and
`hdev->version` to `0x1130` so SDL loads a known Xbox mapping, and reverts both
on disconnect. Seeing "Xbox 360 Controller" is *evidence the right driver
bound*. Do not try to make it report `0x0B13`.

### Pad MACs live in the host layer

A Bluetooth address is machine-specific, the same category as a drive UUID, and
this module is in `commonModules` — every host evaluates it. `xpadneoQuirks`
defaults to `{ }` here; the real MACs are in `hosts/asher/default.nix`.

### `tuneLeLatency` is off by default on purpose

It applies upstream's documented `[LE]` connection parameters
(`MinConnectionInterval=7`, `MaxConnectionInterval=9`, `ConnectionLatency=0`).
BlueZ has no per-device form, so enabling it tightens intervals for *every* LE
peripheral on the adapter — a continuous power cost on a laptop to help one
gamepad. Upstream also describes the symptom it fixes as input that is laggy or
dropping events, not input that is absent, so it is not the knob to reach for
when a pad delivers nothing. And BlueZ's own `main.conf` warns these values
"are superseded by any specific values provided via the Load Connection
Parameters interface" — verify with `journalctl -u bluetooth` around
`load_conn_params` rather than assuming they took.

## Diagnosing a pad that bonds but delivers nothing

`hog-finish-bond --diagnose` is read-only and prints, in one shot: which
xpadneo udev rules are actually installed, every live `hid_xpadneo` module
parameter, the joystick-class event nodes, and `getfacl` plus `udevadm` tags on
the event and hidraw nodes. It exists because this class of bug cannot be
reproduced without the pad in hand.

With the pad connected, the split is one command deep:

```
evtest /dev/input/event<N>          # events here => the kernel side is fine
SDL_JOYSTICK_HIDAPI=0 steam         # works => SDL took the hidraw path
```

- events present **and** `SDL_JOYSTICK_HIDAPI=0` fixes it → the hidraw path;
  check the 70- rule is installed and matched.
- events present, HIDAPI off changes nothing → SDL/Steam mapping.
- **no** events at the evdev layer → BLE or controller firmware. xpadneo logs
  `please upgrade for better stability` on every connect for firmware 5.09, and
  updating it needs the Xbox Accessories app on Windows or an Xbox. Nothing in
  this repo can fix that.

## Gates

```
nix build .#gamepad-bluetooth-tests
```

48 stdlib `unittest` cases, no D-Bus and no KVM. They cover the bonding-policy
allowlist (which `bluetoothctl info` text yields `pair`/`trust`/`noop`, that
keyboards and headphones named "Xbox" are ignored, that trust follows only a
confirmed `Paired=yes`, timeout handling, reconnect planning) and the pure
halves of `--diagnose` (which nodes count as a pad, which rules count as
installed, and that **no diagnostic argv can mutate bond state**).

**What is not measured, stated rather than implied:** that a bonded pad
delivers input. That needs physical BLE hardware and cannot run in a VM, so
`flake.nix`'s gate comment names the gap. It also now names the gap that
actually bit — nothing in a bonding-*policy* gate would ever have noticed a
missing udev rule, which is why the rules derivation asserts their presence
itself.

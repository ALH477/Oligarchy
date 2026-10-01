# custom.gamepadBluetooth — finish BLE HID gamepad bonds without opening BlueZ.
#
# Defaults OFF. Flip it in configuration.nix (or local.nix), do not edit this
# file to "turn it on". Not an always-on service: ISO needs no mkForce.
#
# What this does NOT do (security):
# - Does not set JustWorksRepairing=always (that is a repair/MITM hole).
# - Does not register a NoInputNoOutput pairing agent.
# - Does not Trust() unpaired devices.
# - Does not pair HID keyboards (appearance 0x03c1) or audio sinks.
# - Does not make the adapter discoverable.
#
# Residual: a BLE advertiser spoofing appearance 0x03c4 + HID UUID can get a
# Just-Works Pair(). Same class as the user clicking Pair on a fake gamepad.
#
# ── xpadneo's GameSir-Nova misclassification ────────────────────────────────
#
# Confirmed from the kernel log on every BLE connection of a genuine
# 045E:0B13 (Xbox Series) pad, on this machine:
#
#   xpadneo …: enabling heuristic GameSir Nova quirks
#   xpadneo …: controller quirks: 0x00000057
#
# xpadneo ships a heuristic that guesses a GameSir Nova clone from limited BLE
# advertisement data, and it misfires on a genuine Microsoft-VID pad. 0x57 =
# 0x01 + 0x02 + 0x04 + 0x10 + 0x40, i.e. bits 1+2+4 (no pulse parameters, no
# trigger rumble, no motor masking) OR'd with bits 16 (use Linux button
# mappings) and 64 (use Share button mappings). The last two are what actually
# rewrite the event stream, and bits 1/2/4/64 are GameSir workarounds a genuine
# Microsoft pad needs none of.
#
# Bit 16 is the one to be careful about, and an earlier version of this comment
# got it wrong by lumping it in with the rest: `xpadneo_report_fixup` can set
# bit 16 on its own from a report-descriptor byte match, independently of the
# clone heuristic, and when it does so the bit is CORRECT. See "The override
# REPLACES" below — this is unresolved, not settled.
#
# Meanwhile xpadneo is ALSO spoofing
# this same pad's PID from 0x0B13 to the Xbox-360 0x028E as its documented
# SDL2-mapping workaround (reverted on disconnect) — that PID swap is
# deliberate, correct, and unrelated to the quirks bug. Do NOT "fix" the
# 360 identity; it is evidence the right driver (xpadneo, not hid-generic)
# already bound. The actual defect is that the button-mapping quirks and the
# Xbox-BT profile SDL/Steam loads (keyed off the spoofed PID) now disagree
# with each other.
#
# The fix is `hid_xpadneo`'s own `quirks` modprobe parameter, which lets a
# per-MAC override replace the heuristic outright. Verified against the
# loaded module rather than assumed:
#
#   $ modinfo hid_xpadneo | grep quirks
#   parm: quirks:(string) Override device quirks, specify as:
#     "MAC1:quirks1[,...16]", MAC format = 11:22:33:44:55:66,
#     no pulse parameters = 1, no trigger rumble = 2, no motor masking = 4,
#     hardware profile switch = 8, use Linux button mappings = 16,
#     use Nintendo mappings = 32, use Share button mappings = 64,
#     reversed motor masking = 128, swapped motor masking = 256,
#     apply no heuristics = 512 (array of charp)
#
# 512 ("apply no heuristics") is used rather than hand-picking individual
# bits: this pad needs none of the GameSir workarounds, and enumerating "not
# 16, not 64, and whatever else a future release adds" is a maintenance trap.
#
# But do not read 512 as wider than it is. Upstream's `quirks.c` gates exactly
# ONE heuristic on this bit: the disambiguation that fires when a controller's
# report descriptor is 283 bytes (which this pad's is — see the probe log) and
# decides, from a secondary name/MAC-OUI check, whether it is a GameSir Nova
# clone. The driver's built-in per-device quirk TABLE, which matches on device
# name and MAC OUI, runs unconditionally and is not gated by 512 at all. So
# this is "stop that one misdetection", not "stop guessing forever".
#
# ── The override REPLACES, it does not OR — and that may matter here ────────
#
# `quirks=MAC:N` assigns, it does not merge: the parser does one `kstrtou32`
# and writes the result straight into `devdata->quirks`, discarding whatever
# was already there. Two consequences, the second unresolved:
#
#  1. The value must be complete. There is no "add 512 to the defaults".
#  2. `xpadneo_report_fixup` can itself set bit 16 ("use Linux button
#     mappings") when the descriptor matches a byte pattern at fixed offsets
#     0x8c-0xa3, and it runs BEFORE the override is applied — the probe log
#     shows the descriptor fixups, then `quirks override`, then
#     `controller quirks: 0x00000200`. Bit 16 is not cosmetic: it is what makes
#     `xpadneo_raw_event` repack the dpad/button bits into the Linux gamepad
#     layout. So writing 512 clears bit 16 if the fixup had set it, and the
#     earlier un-overridden boot did report 0x57, which contains it.
#
# Whether this pad NEEDS bit 16 is untested — it needs the hardware. The
# experiment, in order, is: 512 (current), then 528 (512|16), then no override
# at all, checking `evtest` each time. If 528 is what works, say so here and
# keep the reasoning; do not just change the number.
#
# Firmware note (not code): the pad reports BLE firmware 5.09 and xpadneo logs
# `please upgrade for better stability` on EVERY connect — advisory only, it
# never refuses to bind. Upstream also documents that `uhid` is required
# specifically for firmware 5.x and later, which this pad is (see the
# kernelModules line below). Updating it needs the Xbox Accessories app on
# Windows/Xbox — off-box, so it stays a follow-up rather than a fix here.
#
# ── Where the MACs live ──────────────────────────────────────────────────────
#
# `xpadneoQuirks` below is a real option (MAC -> quirks bitmask) rather than a
# literal string baked into `boot.extraModprobeConfig`, precisely because two
# Bluetooth MAC addresses are machine-specific data and this module is a
# shared one (wired into every host's commonModules, gated only by
# `custom.gamepadBluetooth.enable`, which itself defaults to
# `custom.steam.enable` in configuration.nix — so any host with Steam on
# inherits whatever this option resolves to). The architecturally clean home
# for asher's two physical pad MACs is `hosts/asher/default.nix`, the same
# way `swapDevices`'s drive UUID lives there and not in a shared module.
#
# That move is DONE: the default here is `{ }` and the two MACs live in
# `hosts/asher/default.nix`. This paragraph used to say the opposite, and said
# it directly above code that already contradicted it — if you are editing
# this file because a comment disagrees with the config below, the config is
# the one telling the truth.
{ config
, lib
, pkgs
, inputs
, ...
}:

let
  cfg = config.custom.gamepadBluetooth;
  hog = pkgs.writeShellApplication {
    name = "hog-finish-bond";
    runtimeInputs = [
      pkgs.python3
      pkgs.bluez
    ];
    text = ''
      exec ${pkgs.python3}/bin/python3 ${./hog_finish_bond.py} "$@"
    '';
  };

  # ── The two udev rules nixpkgs does not install ──────────────────────────
  #
  # `hardware.xpadneo.enable` gives a working kernel module and NOTHING ELSE.
  # nixpkgs' derivation points `setSourceRoot` at `hid-xpadneo/src`, one
  # directory BELOW where upstream keeps `etc-udev-rules.d/`, and its
  # `installTargets` is `modules_install` alone -- so the output tree is
  # literally one file, `hid-xpadneo.ko.xz`, and the derivation contains no
  # `udev` string anywhere. Upstream installs these rules from its
  # `dkms.post_install` hook, which a Nix build never runs. Both are
  # load-bearing, and the second one is why a bonded pad can deliver nothing:
  #
  #   60-xpadneo.rules           rebinds the pad off hid-generic onto xpadneo,
  #                              then tags the INPUT node `uaccess`, MODE 0664
  #                              and LIBINPUT_IGNORE_DEVICE=1.
  #   70-xpadneo-disable-hidraw  sets the HIDRAW node `MODE:="0000"` and
  #                              `TAG-="uaccess"`.
  #
  # That second rule exists because Steam's own `60-steam-input.rules` grants
  # hidraw access while the pad is still bound to hid-generic, and SDL's HIDAPI
  # backend then claims the pad through that raw node IN PREFERENCE TO
  # xpadneo's translated evdev stream -- where it reads HID-over-GATT reports
  # it cannot interpret. With the rule absent nothing ever takes that access
  # away, so the kernel log looks perfect (descriptor fixups applied, Linux
  # Gamepad Spec compliance on, the connect-notify rumble physically firing)
  # while games see nothing at all. Steam's log names it:
  # `Controller using HIDAPI driver, vid=0x045e, pid=0x028e` followed by
  # `Controller device closed after hid_read failure`.
  #
  # Do NOT "fix" this by granting the pad's hidraw node uaccess. That is the
  # exact inverse of the fix and would make the bug permanent.
  #
  # Taken from the xpadneo package's OWN `src` rather than copied inline, so
  # the rules can never drift from the module version they belong to -- the
  # discipline modules/terminal/patches/README.md sets for carried-upstream
  # material. Upstream's filenames are kept verbatim because the NUMBERING is
  # semantic: `60-steam-input` sorts before `60-xpadneo` (s < x) so the rebind
  # wins, and the 70- rule must run after both.
  #
  # Known remaining gap, not papered over: xpadneo 0.9.7's rules trigger on
  # `ACTION=="add"`/`"add|change"`. Upstream 0.10+ widened both to
  # `ACTION!="remove"`, and a NixOS report against systemd 258 (which is what
  # this host runs) describes the first post-boot connection working while
  # RECONNECTS regress to /dev/hidraw*. If that shows up here, the fix is the
  # 0.10.x rules, i.e. bumping the package -- not editing these files.
  # nixpkgs 25.11 pins xpadneo 0.9.7; upstream is at 0.10.4 and nixpkgs master
  # already carries it. Taken here rather than waiting, for one reason that is
  # not cosmetic: 0.9.7's udev rules trigger on `ACTION=="add"` /
  # `"add|change"`, and 0.10 widened BOTH to `ACTION!="remove"`. Under systemd
  # 258 — which is what this host runs — the narrow form is reported to let the
  # first post-boot connection work while RECONNECTS fall back to /dev/hidraw*,
  # i.e. exactly the defect the 70- rule exists to prevent, returning on the
  # second connect. Shipping 0.9.7's rules would be a fix that works once.
  #
  # 0.10 also orders uhid loading ahead of bluetooth and 0.10.2 reworked the
  # HID-over-GATT rumble path; both are the transport this pad actually uses.
  #
  # The source comes from the `xpadneo-src` flake input, not a fetch here --
  # AGENTS.md's "pin via flake inputs, not ad-hoc fetches" rule. flake.nix
  # carries the reasoning for why this input exists at all.
  #
  # `version` must be kept in step with the input's tag by hand. It is not
  # cosmetic: nixpkgs' recipe interpolates it into `makeFlags` as `VERSION=`,
  # which is what the driver reports to `modinfo`. The rules derivation below
  # asserts the two agree, so a bumped input with a stale version here fails
  # the build rather than shipping a module that lies about itself.
  xpadneoVersion = "0.10.4";
  xpadneoPkg = config.boot.kernelPackages.xpadneo.overrideAttrs (_: {
    version = xpadneoVersion;
    src = inputs.xpadneo-src;
    # A flake input is a bare store path with no `name`, so nixpkgs' own
    # `setSourceRoot` -- which interpolates `finalAttrs.src.name` -- cannot be
    # reused. Glob instead of hardcoding the unpacked directory name, which is
    # derived from the store path and is not ours to predict.
    # Absolute, not relative: the recipe passes `M=$(sourceRoot)` to a
    # `make -C <kernel build dir>`, so a relative path resolves against the
    # kernel tree and kbuild reports the module directory as nonexistent.
    setSourceRoot = ''
      export sourceRoot="$(pwd)/$(echo */hid-xpadneo/src)"
    '';
    # The 25.11 recipe carries a backport patch against the 0.9.7 tree.
    patches = [ ];
  });
  xpadneoUdevRules =
    pkgs.runCommand "xpadneo-udev-rules-${xpadneoPkg.version}" { } ''
      rules="${xpadneoPkg.src}/hid-xpadneo/etc-udev-rules.d"
      for f in 60-xpadneo.rules 70-xpadneo-disable-hidraw.rules; do
        # A silently-missing rule is the whole defect this exists to fix, so an
        # upstream layout change must fail the build rather than install less.
        test -f "$rules/$f" || { echo "xpadneo-udev-rules: $f missing from src" >&2; exit 1; }
      done

      # `xpadneoVersion` is hand-maintained against the input's tag and feeds
      # the driver's own VERSION. If the input moves and the string does not,
      # fail here rather than ship a module reporting the wrong version.
      # Upstream writes the tag form, `v0.10.4`; xpadneoVersion is the bare
      # number because that is what `VERSION=` wants. Compare without the
      # prefix rather than storing it twice in two shapes.
      want="${xpadneoVersion}"
      got="$(cat "${xpadneoPkg.src}/VERSION" 2>/dev/null || echo "")"
      got="''${got#v}"
      if [ -n "$got" ] && [ "$got" != "$want" ]; then
        echo "xpadneo-udev-rules: input is '$got', xpadneoVersion says '$want'" >&2
        exit 1
      fi
      install -D -m0644 -t "$out/lib/udev/rules.d" \
        "$rules/60-xpadneo.rules" \
        "$rules/70-xpadneo-disable-hidraw.rules"
    '';
in
{
  options.custom.gamepadBluetooth = {
    enable = lib.mkEnableOption ''
      Finish Bluetooth LE HID gamepad bonding (Xbox Series/One) and enable xpadneo.
      Pairs only appearance 0x03c4 + HID UUID devices that are already connected
      and unbonded. Trusts only after Paired=yes.
    '';

    xpadneoQuirks = lib.mkOption {
      type = lib.types.attrsOf lib.types.ints.unsigned;
      default = { };
      example = {
        "74:C4:12:ED:8F:76" = 512;
      };
      description = ''
        Per-MAC overrides for hid_xpadneo's `quirks` modprobe parameter,
        keyed by the pad's Bluetooth MAC address (`AA:BB:CC:DD:EE:FF`,
        xpadneo's own colon-separated format — see `modinfo hid_xpadneo`).
        Each value is the raw quirks bitmask for that one controller; 512
        ("apply no heuristics") is the value that defeats xpadneo's
        GameSir-Nova misclassification heuristic — see the header comment
        above. Machine-specific: a host with its own pads should set this
        in its own host layer rather than editing the default here.
      '';
    };

    tuneLeLatency = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Apply upstream xpadneo's documented BlueZ `[LE]` connection parameters
        (`MinConnectionInterval=7`, `MaxConnectionInterval=9`,
        `ConnectionLatency=0`) from its `docs/TROUBLESHOOTING.md` section
        "High Latency or Lost Button Events with Bluetooth LE", which names
        Xbox Series X|S and later as the affected models.

        Off by default, and that default is deliberate rather than timid.
        BlueZ has no per-device form of these keys, so enabling this tightens
        connection intervals for **every** LE peripheral on the adapter — on a
        laptop that is a power cost paid continuously to help one gamepad.
        Upstream also describes the symptom it fixes as input that is *laggy,
        choppy or dropping events*, not input that is absent, so it is a
        comfort fix and not the one to reach for when a pad delivers nothing
        (for that, see the udev rules in this module's header comment).

        Known caveat, not papered over: BlueZ's own `main.conf` says these
        values "are superseded by any specific values provided via the Load
        Connection Parameters interface", and bluez/bluez#293 reports a case
        where none were loaded onto the adapter at all despite `main.conf`
        being populated. Verify rather than assume — `journalctl -u bluetooth`
        around `load_conn_params` says whether they took.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # Deliberately NOT `hardware.xpadneo.enable = true`. That module hardcodes
    # `config.boot.kernelPackages.xpadneo`, so with the version override above
    # it would install the 0.9.7 module ALONGSIDE ours — two hid-xpadneo.ko in
    # one modules tree. Its entire config body is the three lines below plus a
    # `disable_ertm` modprobe line gated on `kernel < 5.12`, which no kernel
    # this repo supports can satisfy, so nothing is lost by inlining it.
    boot.extraModulePackages = [ xpadneoPkg ];

    # See the "two udev rules" block above. Lazy, so `enable = false` never
    # forces the derivation and the ISO still needs no mkForce.
    services.udev.packages = [ xpadneoUdevRules ];

    # mkDefault so a host or local.nix can still override an individual key;
    # configuration.nix owns the `General`/`Policy` sections and this adds a
    # section it does not set, so the two merge rather than fight.
    hardware.bluetooth.settings = lib.mkIf cfg.tuneLeLatency {
      LE = {
        MinConnectionInterval = lib.mkDefault 7;
        MaxConnectionInterval = lib.mkDefault 9;
        ConnectionLatency = lib.mkDefault 0;
      };
    };

    # No MACs here on purpose. A Bluetooth address is machine-specific data,
    # the same category as a drive UUID, and this module is in commonModules —
    # every host evaluates it. The pads that need the quirk override are
    # declared in hosts/asher/default.nix; see "Where the MACs live" above.

    # `types.lines`, so this concatenates with any other module's
    # extraModprobeConfig rather than clobbering it (configuration.nix,
    # dsp-guest.nix, ci-builder.nix and others all contribute lines too).
    boot.extraModprobeConfig = lib.mkIf (cfg.xpadneoQuirks != { }) ''
      options hid_xpadneo quirks=${
        lib.concatStringsSep "," (
          lib.mapAttrsToList (mac: quirks: "${mac}:${toString quirks}") cfg.xpadneoQuirks
        )
      }
    '';

    # BlueZ HID-over-GATT instantiates the pad through uhid. If the module
    # is not loaded, Pair+Trust succeed and /dev/input/js* never appears.
    # uhid: BlueZ's HID-over-GATT instantiates the pad through it, and upstream
    # requires it specifically for controller firmware 5.x+. Without it, Pair
    # and Trust both succeed and /dev/input/js* never appears.
    boot.kernelModules = [ "hid_xpadneo" "uhid" ];

    environment.systemPackages = [ hog ];

    systemd.services.gamepad-hog-bond = {
      description = "Finish BLE HID gamepad bonding (allowlisted appearance only)";
      after = [ "bluetooth.service" ];
      wants = [ "bluetooth.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${hog}/bin/hog-finish-bond";
        # A udev SYSTEMD_WANTS trigger arriving mid-run merges into the running
        # job instead of queueing a new one, so an unbounded run means a second
        # pad powered on during a hung pair is never classified.
        TimeoutStartSec = "120s";
        # bluetoothctl talks to bluetoothd over the system bus only.
        RestrictAddressFamilies = [ "AF_UNIX" ];
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        CapabilityBoundingSet = "";
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        RestrictSUIDSGID = true;
        SystemCallArchitectures = "native";
        Nice = 10;
      };
      path = [
        pkgs.bluez
        pkgs.python3
      ];
    };

    # udev RUN+= blocks the daemon. Tag the bluetooth device add so systemd
    # starts the oneshot instead.
    services.udev.extraRules = ''
      ACTION=="add", SUBSYSTEM=="bluetooth", TAG+="systemd", ENV{SYSTEMD_WANTS}+="gamepad-hog-bond.service"
    '';
  };
}

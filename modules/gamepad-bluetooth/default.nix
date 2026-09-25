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
# mappings) and 64 (use Share button mappings). The last two are what
# actually rewrite the event stream — wrong for this pad, which needs none of
# the GameSir workarounds at all. Meanwhile xpadneo is ALSO spoofing
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
# bits: this pad needs zero of the GameSir workarounds, and enumerating "not
# 16, not 64, and whatever else a future xpadneo release adds to the
# heuristic" is a maintenance trap that 512 sidesteps by construction — it
# tells xpadneo to stop guessing for this MAC entirely, full stop, forever.
#
# Firmware note (not code): the pad reports BLE firmware 5.09 and xpadneo
# warns to upgrade. 5.13+ plausibly stops the misclassification at its
# source, but updating it needs the Xbox Accessories app on Windows/Xbox —
# off-box, so it stays a follow-up rather than a fix here.
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
# That file was locked to a concurrent stream while this option was added
# (see AGENT_HANDOFF / the plan's Part C stream split), so the two MACs are
# set here instead, as this option's own `mkDefault` — low blast radius even
# left in place, since a MAC that never appears in a controller's
# advertisement is simply an inert entry in the modprobe line. Follow-up:
# move the two lines below into `hosts/asher/default.nix` as
# `custom.gamepadBluetooth.xpadneoQuirks = { ... };` and delete the default
# here, so a second, unrelated host with Steam on does not silently gain
# quirks overrides for gamepads it will never see.
{ config
, lib
, pkgs
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
  };

  config = lib.mkIf cfg.enable {
    hardware.xpadneo.enable = true;

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
    boot.kernelModules = [ "uhid" ];

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

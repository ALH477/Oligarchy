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
  options.custom.gamepadBluetooth.enable = lib.mkEnableOption ''
    Finish Bluetooth LE HID gamepad bonding (Xbox Series/One) and enable xpadneo.
    Pairs only appearance 0x03c4 + HID UUID devices that are already connected
    and unbonded. Trusts only after Paired=yes.
  '';

  config = lib.mkIf cfg.enable {
    hardware.xpadneo.enable = true;

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

# custom.androidMirror — USB scrcpy phone-mirror.
#
# Defaults OFF. Flip it in configuration.nix (or local.nix), do not edit this
# file to "turn it on". Not an always-on service: ISO needs no mkForce.
#
# programs.adb.enable is the udev + adbusers half. The package is the wrapped
# scrcpy from this subflake, not pkgs.scrcpy, so the game flags travel with
# the enable bit.
self:
{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.custom.androidMirror;
  suite = self.packages.${pkgs.stdenv.hostPlatform.system}.default;
in
{
  options.custom.androidMirror.enable = lib.mkEnableOption ''
    USB scrcpy phone-mirror: low-latency Android game display (`phone-mirror`).
    Adds the user to adbusers, installs android udev rules, and disables USB
    autosuspend on ADB interfaces.
  '';

  config = lib.mkIf cfg.enable {
    programs.adb.enable = true;

    users.users.${config.custom.user.name}.extraGroups = [ "adbusers" ];

    environment.systemPackages = [ suite ];

    services.udev.extraRules = ''
      # ADB (class 0xff / subclass 0x42 / protocol 0x01). Autosuspend mid-frame
      # is why USB game mirrors hitch after a few minutes of sitting still.
      ACTION=="add", SUBSYSTEM=="usb", ENV{ID_USB_INTERFACES}=="*:ff4201:*", TEST=="power/control", ATTR{power/control}="on"
    '';
  };
}

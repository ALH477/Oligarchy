# Edit this configuration file to define what should be installed on
# your system.  Help is available in the configuration.nix(5) man page
# and in the NixOS manual (accessible by running 'nixos-help').
# NOTE: this is the stock template calamares-nixos-extensions writes
# (pkgs/by-name/ca/calamares-nixos-extensions/src/modules/nixos/main.py).
# It is a fixture: trimmed to the keys oligarchy-adopt reads.

{ config, lib, pkgs, ... }:

{
  imports =
    [
      # Include the results of the hardware scan.
      ./hardware-configuration.nix
    ];

  # Set your time zone.
  time.timeZone = "Europe/Berlin";

  # Select internationalisation properties.
  i18n.defaultLocale = "de_DE.UTF-8";

  # Configure keymap in X11
  services.xserver.xkb.layout = "de";
  services.xserver.xkb.variant = "nodeadkeys";

  # Configure console keymap
  console.keyMap = "de-latin1-nodeadkeys";

  system.stateVersion = "25.11";
}

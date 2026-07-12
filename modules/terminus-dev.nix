# Terminus Developer Edition — local-only app wrapper
# Wraps the existing demod-ui binary + unified-UI Lua scripts as a launchable
# NixOS app. No source code is committed or fetched — references local working
# directories only. Safe to commit to the public Oligarchy repo (no paths leak
# source, and the private repos stay in ~/demod-private-git/).
{ config, lib, pkgs, ... }:

let
  cfg = config.custom.terminus-dev;

  # Paths to the local working trees (developer machine only)
  demodUiBin = "/home/asher/demod-ui/demod-ui";
  unifiedUiDir = "/home/asher/Downloads/unified-UI";

  terminus-launcher = pkgs.writeShellScriptBin "terminus" ''
    exec ${demodUiBin} "${unifiedUiDir}/home.lua" "$@"
  '';

  terminus-dsp = pkgs.writeShellScriptBin "terminus-dsp" ''
    exec ${demodUiBin} "${unifiedUiDir}/dsp/dsp_studio.lua" "$@"
  '';

  terminus-desktop = pkgs.makeDesktopItem {
    name = "terminus";
    desktopName = "Terminus Dev";
    comment = "DeMoD Terminus — developer edition";
    exec = "terminus";
    icon = "applications-system";
    categories = [ "Development" "AudioVideo" ];
    startupNotify = false;
  };

  terminus-dsp-desktop = pkgs.makeDesktopItem {
    name = "terminus-dsp";
    desktopName = "Terminus DSP Studio";
    comment = "DeMoD DSP Studio — developer edition";
    exec = "terminus-dsp";
    icon = "applications-system";
    categories = [ "Development" "AudioVideo" ];
    startupNotify = false;
  };
in
{
  options.custom.terminus-dev = {
    enable = lib.mkEnableOption "Terminus developer edition (local-only app)";
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      terminus-launcher
      terminus-dsp
      terminus-desktop
      terminus-dsp-desktop
    ];
  };
}

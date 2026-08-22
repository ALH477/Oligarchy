# ═══════════════════════════════════════════════════════════════════════════════
# Desktop Features — makes the Home Manager feature set overridable
# ═══════════════════════════════════════════════════════════════════════════════
# home/home.nix used to hardcode its `features` set (enableDev/enableGaming/
# enableAudio/enableDCF, plus the personal package list and the Hyprland
# scratchpad terminals downstream of it). That made a fresh clone come loaded
# with a full personal desktop with no way to turn it off short of editing
# home/home.nix directly. These options let a fresh clone default to a
# minimal desktop while a local override (see configuration.nix's
# ~/.config/oligarchy/local.nix import) restores the real setup.
{ lib, ... }:

with lib;

{
  options.custom.desktopFeatures = {
    enableDev = mkOption {
      type = types.bool;
      default = false;
      description = "Dev-workflow home-manager pieces (editor/VCS keybinds, repo-updates widget, dev packages in home/packages.nix).";
    };

    enableGaming = mkOption {
      type = types.bool;
      default = false;
      description = "Gaming-related home-manager packages (steam, gamescope, mangohud, gamemode, lutris, wine).";
    };

    enableAudio = mkOption {
      type = types.bool;
      default = false;
      description = "Audio/DSP-related home-manager pieces (waybar DSP widget, etc.).";
    };

    enableDCF = mkOption {
      type = types.bool;
      default = false;
      description = "DCF-related home-manager pieces.";
    };

    enableScratchpads = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Auto-launch the three hidden Hyprland scratchpad terminals on login
        (idle shell, notes in nvim, htop). Off by default: htop in particular
        runs continuously and is a non-obvious idle-resource cost on a fresh
        install.
      '';
    };

    enablePersonalApps = mkOption {
      type = types.bool;
      default = false;
      description = ''
        The bulk of the personal package list (DAWs/audio-production, SDR
        tools, games, creative apps, Android tooling, browsers/office,
        general dev toolchain) in both configuration.nix's
        environment.systemPackages and home/packages.nix. Off by default so
        a fresh clone gets a working desktop, not the maintainer's full app
        collection.
      '';
    };
  };
}

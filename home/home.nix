{ config, pkgs, lib, ... }:

let
  user = "asher";
  homeDirectory = "/home/${user}";

  # ── Theme ──────────────────────────────────────────────────────────────────
  # Single source of truth: home/themes/default.nix. Every module below
  # receives this palette via _module.args.theme.
  themeSystem = import ./themes { inherit lib; };
  activeTheme = themeSystem.palettes.demod;

  # ── Features ───────────────────────────────────────────────────────────────
  # Static Framework 16 laptop profile. Deliberately NOT lib.pathExists:
  # impure /sys probes break pure flake eval and lie when building on another
  # machine. This config targets exactly one laptop — say so.
  features = {
    hasBattery = true;
    hasTouchpad = true;
    hasBacklight = true;
    hasBluetooth = true;
    enableDev = true;
    enableGaming = true;
    enableAudio = true;
    enableDCF = false;
    enableAIStack = false;
    sessionType = "wayland";
    x11Wm = "icewm";
  };
in {
  # ── Module wiring ──────────────────────────────────────────────────────────
  # This is what makes the modular tree LIVE. Before this, home.nix imported
  # nothing and the entire packages/hyprland/waybar/apps/scripts tree was
  # dead code (the system ran on stale configs from the old monolith).
  imports = [
    ./packages.nix
    ./hyprland
    ./waybar
    ./terminal
    ./shell
    ./apps
    ./scripts
  ];

  # Inject theme/features/username into every imported module. Modules take
  # `theme ? {}`, `features ? {}`, `username ? "asher"` — these args override
  # those defaults. (imports can't depend on _module.args; static paths above
  # are fine.)
  _module.args = {
    theme = activeTheme;
    inherit features;
    username = user;
  };

  home = {
    inherit homeDirectory;
    username = user;
    stateVersion = "25.11";

    sessionVariables = {
      EDITOR = "nvim";
      BROWSER = "brave";
      TERMINAL = "kitty";
    };
    sessionPath = [ "$HOME/.local/bin" ];

    file."Pictures/Screenshots/.keep".text = "";
    file.".config/hypr/wallpapers/.keep".text = "";
    file.".local/bin/.keep".text = "";
  };

  home.pointerCursor = {
    gtk.enable = true;
    x11.enable = true;
    package = pkgs.bibata-cursors;
    name = "idTech4";
    size = 24;
  };

  fonts.fontconfig.enable = true;

  programs.home-manager.enable = true;
}

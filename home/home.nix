{ config, pkgs, lib, primaryUsername ? "asher", osConfig ? { }, ... }:

let
  user = primaryUsername;
  homeDirectory = "/home/${user}";

  # ── Theme ──────────────────────────────────────────────────────────────────
  # Single source of truth: home/themes/default.nix. Every module below
  # receives the active palette via _module.args.theme, and the full palette
  # set via _module.args.themes (for rendering per-theme variant files so
  # theme-switch.sh can flip live without a rebuild — see home/apps/theme-
  # variants.nix). Change the default by editing activeThemeName there, not
  # here, so there is exactly one place that picks the build-time default.
  themeSystem = import ./themes { inherit lib; };
  activeTheme = themeSystem.activePalette;

  # ── Features ───────────────────────────────────────────────────────────────
  # hasBattery/hasTouchpad/hasBacklight/hasBluetooth/sessionType/x11Wm are a
  # static Framework 16 laptop profile. Deliberately NOT lib.pathExists:
  # impure /sys probes break pure flake eval and lie when building on another
  # machine. This config targets exactly one laptop — say so.
  #
  # The enable* flags used to be hardcoded true here, which meant a fresh
  # clone came loaded with the maintainer's full personal desktop with no way
  # to turn it off. They now come from custom.desktopFeatures (see
  # modules/desktop-features.nix), which defaults to false everywhere — a
  # local override outside the repo restores the real setup on the
  # maintainer's own machine (see configuration.nix's local-override import).
  desktopFeatures = osConfig.custom.desktopFeatures or { };
  features = {
    hasBattery = true;
    hasTouchpad = true;
    hasBacklight = true;
    hasBluetooth = true;
    enableDev = desktopFeatures.enableDev or false;
    enableGaming = desktopFeatures.enableGaming or false;
    enableAudio = desktopFeatures.enableAudio or false;
    enableDCF = desktopFeatures.enableDCF or false;
    enableAIStack = false; # unused downstream; kept for API parity
    enableScratchpads = desktopFeatures.enableScratchpads or false;
    enablePersonalApps = desktopFeatures.enablePersonalApps or false;
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
  # are fine.) `user` itself comes from `primaryUsername`, passed in via
  # flake.nix's hmModule from `custom.user.name` (modules/user.nix) — change
  # that option, not this file, when forking for another account.
  _module.args = {
    theme = activeTheme;
    themes = themeSystem.palettes;
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
      # Default agent command for oligarchy-ctl's "Launch coding agent" menu
      # entry (oligarchy-forge run -- $OLIGARCHY_FORGE_AGENT). Override here
      # rather than in the script, e.g. to "aider" or "omp".
      OLIGARCHY_FORGE_AGENT = "claude";
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

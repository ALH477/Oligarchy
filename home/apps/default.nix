{ config, pkgs, lib, theme ? { }, features ? { }, username ? "asher", ... }:

let
  p = theme; # Shorthand for palette
in
{
  # ════════════════════════════════════════════════════════════════════════════
  # Qt/GTK Theming + Hyprland App Modules
  # ════════════════════════════════════════════════════════════════════════════
  # KDE/Plasma session modules (kde-globals/kwin/plasma/input/baloo/colorscheme,
  # dolphin, konsole) were removed with the Plasma desktop — Hyprland is the sole
  # session. Kvantum/Qt/GTK theming stays for remaining Qt apps (kdenlive, qt6ct).
  imports = [
    ./kvantum.nix # Kvantum Qt theme engine (theme-aware)
    ./qt-theming.nix # Qt5/6 configuration
    ./gtk-theming.nix # GTK 3/4 theming (theme-aware)
    ./wofi.nix # Wofi launcher config
    ./wlogout.nix # Wlogout power menu
    ./hyprlock.nix # Hyprlock screen lock
    ./control-center.nix # Unified control hub (oligarchy-menu / -control / -ctl)
  ];

  # ════════════════════════════════════════════════════════════════════════════
  # Mako Notifications
  # ════════════════════════════════════════════════════════════════════════════
  services.mako = {
    enable = true;
    settings = {
      background-color = p.surface + "f2"; # Surface with 95% opacity
      text-color = p.text;
      border-color = p.accent;
      border-radius = 14;
      border-size = 2;
      padding = "14";
      margin = "12";
      default-timeout = 5000;
      font = "JetBrains Mono 11";
      icons = true;
      max-icon-size = 48;
      layer = "overlay";
      anchor = "top-right";
      width = 380;
      max-visible = 4;
      sort = "-time";
      progress-color = "over ${p.accent}";

      # Urgency levels
      "urgency=low" = {
        border-color = p.textDim;
        default-timeout = 3000;
      };
      "urgency=normal" = {
        border-color = p.accent;
        default-timeout = 5000;
      };
      "urgency=critical" = {
        border-color = p.error;
        default-timeout = 0;
        ignore-timeout = true;
      };
    };
  };

  # ════════════════════════════════════════════════════════════════════════════
  # Git
  # ════════════════════════════════════════════════════════════════════════════
  programs.git = {
    enable = true;
    settings = {
      user.name = "Asher";
      # was "${username}@localhost" — every commit authored on this box would
      # carry an unroutable identity GitHub can't associate with your account.
      user.email = "demodllc@gmail.com";
      init.defaultBranch = "main";
      pull.rebase = true;
      push.autoSetupRemote = true;
      core.editor = "nvim";
    };
  };

  # LazyGit - TUI Git client
  programs.lazygit = lib.mkIf (features.enableDev or false) {
    enable = true;
  };

  # GitHub CLI
  programs.gh = lib.mkIf (features.enableDev or false) {
    enable = true;
    settings = {
      git_protocol = "ssh";
    };
  };

  # Additional app configurations (rofi, dunst, etc.) would go here
  # Import from separate files if they get large:
  # imports = [ ./rofi.nix ./dunst.nix ];
}

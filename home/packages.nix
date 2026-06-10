{ config, pkgs, lib, features, ... }:

{
  home.packages = with pkgs; lib.flatten [
    # ══════════════════════════════════════════════════════════════════════════
    # Fonts
    # ══════════════════════════════════════════════════════════════════════════
    [ 
      jetbrains-mono
      nerd-fonts.jetbrains-mono
      font-awesome
      noto-fonts
      noto-fonts-color-emoji
      inter
    ]

    # ══════════════════════════════════════════════════════════════════════════
    # Hyprland Ecosystem
    # ══════════════════════════════════════════════════════════════════════════
    [ hyprpaper hypridle hyprlock hyprpicker ]

    # ══════════════════════════════════════════════════════════════════════════
    # Command Line Utils
    # ══════════════════════════════════════════════════════════════════════════
    [ 
      grim slurp swappy              # Screenshots
      cliphist wl-clipboard          # Clipboard
      jq ripgrep fd eza bat fzf      # CLI tools
      libnotify wtype                # Notifications & typing
      wlr-randr xdg-utils            # Wayland utilities
      lm_sensors                     # Hardware monitoring
    ]

    # ══════════════════════════════════════════════════════════════════════════
    # System Services
    # ══════════════════════════════════════════════════════════════════════════
    [ udiskie polkit_gnome networkmanagerapplet ]
    (lib.optional (features.hasBluetooth or false) blueman)

    # ══════════════════════════════════════════════════════════════════════════
    # UI - Launchers & Menus
    # ══════════════════════════════════════════════════════════════════════════
    [ wofi wlogout ]
    
    # ══════════════════════════════════════════════════════════════════════════
    # Qt/KDE Theming
    # ══════════════════════════════════════════════════════════════════════════
    [
      libsForQt5.qt5ct                     # Qt5 config tool
      kdePackages.qt6ct                   # Qt6 config tool
      libsForQt5.qtstyleplugin-kvantum    # Qt5 Kvantum theme
      kdePackages.qtstyleplugin-kvantum   # Qt6 Kvantum theme
      papirus-icon-theme
      bibata-cursors
      # adwaita-qt / adwaita-qt6 removed: abandoned upstream, marked broken /
      # dropped in current nixpkgs. Kvantum + qt6ct above cover Qt theming.
    ]

    # ══════════════════════════════════════════════════════════════════════════
    # Desktop Applications
    # ══════════════════════════════════════════════════════════════════════════
    [ 
      brave
      xfce.thunar
      xfce.tumbler
      vlc
      gnome-calculator
      gnome-system-monitor
      thunderbird
      libreoffice-qt6-fresh
    ]
    
    # Development Tools (conditional)
    (lib.optionals (features.enableDev or false) [ 
      vscode-fhs
      obsidian
      git
      gh
      lazygit
      btop
    ])
    
    # Gaming (conditional)
    (lib.optionals (features.enableGaming or false) [ 
      steam
      gamescope           # Micro-compositor for games
      mangohud            # Performance overlay
      gamemode            # CPU/GPU optimization daemon
      lutris              # Game launcher
      wine-staging        # Wine with gaming patches
      winetricks          # Wine helper
      protontricks        # Proton helper
      dxvk                # DirectX to Vulkan
      vkd3d-proton        # DirectX 12 to Vulkan
    ])

    # ══════════════════════════════════════════════════════════════════════════
    # Media & Audio
    # ══════════════════════════════════════════════════════════════════════════
    [ 
      wireplumber
      pavucontrol
      playerctl
      easyeffects
      helvum
      gpu-screen-recorder
      imagemagick
      ffmpeg
      gnome-keyring
    ]
    (lib.optional (features.hasBacklight or false) brightnessctl)

    # ══════════════════════════════════════════════════════════════════════════
    # XWayland & X11 Compatibility
    # ══════════════════════════════════════════════════════════════════════════
    [ 
      xorg.xrandr          # XWayland display config
      xorg.xprop           # Window properties
      xorg.xdpyinfo        # Display info
      xorg.xhost           # X server access control
      xclip                # X11 clipboard (for legacy apps)
      xsel                 # X11 selections
    ]
  ];

  # ════════════════════════════════════════════════════════════════════════════
  # XDG Directories
  # ════════════════════════════════════════════════════════════════════════════
  xdg = {
    enable = true;
    userDirs = {
      enable = true;
      createDirectories = true;
      desktop = "${config.home.homeDirectory}/Desktop";
      documents = "${config.home.homeDirectory}/Documents";
      download = "${config.home.homeDirectory}/Downloads";
      music = "${config.home.homeDirectory}/Music";
      pictures = "${config.home.homeDirectory}/Pictures";
      videos = "${config.home.homeDirectory}/Videos";
      extraConfig = { 
        XDG_SCREENSHOTS_DIR = "${config.home.homeDirectory}/Pictures/Screenshots";
      };
    };
    # xdg.portal removed at the HM level: the user-scope portals.conf it
    # generates takes precedence over the system config in EVERY session, so
    # forcing [hyprland gtk] here broke portals (screenshots, file pickers,
    # screen share) inside Plasma. The system-level xdg.portal in
    # configuration.nix already declares kde + hyprland + gtk per-desktop.
  };
}

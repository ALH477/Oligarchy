{ config, pkgs, lib, inputs, ... }:

let
  # ════════════════════════════════════════════════════════════════════════════
  # DeMoD Theme System - Production UI/UX Configuration
  # ════════════════════════════════════════════════════════════════════════════
  #
  # A comprehensive theming system with multiple palettes and consistent
  # styling across all components. Switch palettes with Super+F8.
  #
  # ════════════════════════════════════════════════════════════════════════════

  username = "asher";
  homeDirectory = "/home/${username}";

  # ──────────────────────────────────────────────────────────────────────────────
  # Color Palettes - Each palette has a complete color scheme
  # ──────────────────────────────────────────────────────────────────────────────
  palettes = {
    # ══════════════════════════════════════════════════════════════════════════
    # DeMoD - Radical Retro-Tech Palette
    # ══════════════════════════════════════════════════════════════════════════
    # Anti-corporate. 80s/90s arcade & terminal aesthetics.
    # CRT phosphor glow, synthwave nights, hacker terminals.
    # Turquoise > Blue. Violet > Gray. Chaos > Order.
    # ══════════════════════════════════════════════════════════════════════════
    demod = {
      name = "DeMoD";
      
      # ── Backgrounds ─────────────────────────────────────────────────────────
      # Deep CRT blacks - true darkness for white text contrast
      # Not corporate white. Not safe gray. The void.
      bg = "#080810";           # Near-black with cool undertone
      bgAlt = "#0C0C14";        # Slightly elevated
      surface = "#101018";      # Panel/card - deep space
      surfaceAlt = "#161620";   # Elevated surface
      overlay = "#1C1C28";      # Modal overlay
      
      # ── Borders ─────────────────────────────────────────────────────────────
      # Subtle until focused, then NEON
      border = "#252530";       # Dormant circuit trace
      borderFocus = "#00F5D4";  # ACTIVATED - turquoise lightning
      
      # ── Primary Accent: Turquoise/Cyan ──────────────────────────────────────
      # NOT corporate blue. This is terminal green's cooler sibling.
      # The color of old oscilloscopes, submarine sonar, hacker screens.
      accent = "#00F5D4";       # Primary - electric turquoise
      accentAlt = "#00E5C7";    # Slightly deeper
      accentDim = "#00B89F";    # Muted for less important elements
      
      # ── Gradient ────────────────────────────────────────────────────────────
      # Turquoise to electric violet - abstract and clean
      gradientStart = "#00F5D4";  # Electric turquoise
      gradientEnd = "#8B5CF6";    # Electric violet (cleaner than magenta)
      gradientAngle = "135deg";   # Diagonal slash
      
      # ── Text ────────────────────────────────────────────────────────────────
      # Clean white on black - maximum contrast, maximum clarity
      text = "#FFFFFF";         # Pure white - clean and readable
      textAlt = "#E0E0E0";      # Secondary - soft white
      textDim = "#808080";      # Disabled - neutral gray
      textOnAccent = "#080810"; # Reversed - dark on bright
      
      # ── Semantic Colors ─────────────────────────────────────────────────────
      # Bold. Saturated. No corporate pastels here.
      success = "#39FF14";      # ELECTRIC GREEN - 80s terminal success
      warning = "#FFE814";      # BANANA YELLOW - arcade coin flash
      error = "#FF3B5C";        # CORAL RED - vivid but not aggressive
      info = "#00F5D4";         # Turquoise - information is power
      
      # ── Feature Colors ──────────────────────────────────────────────────────
      # The retro spectrum - saturated and unapologetic
      purple = "#8B5CF6";       # ELECTRIC VIOLET - clean and abstract
      pink = "#A78BFA";         # SOFT VIOLET - lighter variant
      orange = "#FF9500";       # AMBER - warm accent
      violet = "#8B5CF6";       # ELECTRIC VIOLET - secondary accent
      
      # ── Border States (per Design System) ───────────────────────────────────
      borderHover = "#8B5CF6";  # Hovered elements - electric violet
      
      # ── Glow Shadows (per Design System) ────────────────────────────────────
      glowTurquoise = "0 0 20px rgba(0, 245, 212, 0.3)";
      glowViolet = "0 0 20px rgba(139, 92, 246, 0.3)";
      
      # ── Terminal Colors ─────────────────────────────────────────────────────
      # Full 16-color palette with white text emphasis
      black = "#080810";        # True dark
      brightBlack = "#404050";  # Visible comments
      red = "#FF3B5C";          # Coral red
      brightRed = "#FF6B7F";    # Softer red
      green = "#39FF14";        # Electric terminal green
      brightGreen = "#69FF4D";  # Highlighted success
      yellow = "#FFE814";       # Banana warning
      brightYellow = "#FFEF5C"; # Soft highlight
      blue = "#00B4D8";         # Teal-shifted blue
      brightBlue = "#00F5D4";   # Turquoise - our signature
      magenta = "#8B5CF6";      # Electric violet
      brightMagenta = "#A78BFA";# Soft violet
      cyan = "#00F5D4";         # Electric turquoise
      brightCyan = "#5CFFE8";   # Glowing cyan
      white = "#E0E0E0";        # Soft white
      brightWhite = "#FFFFFF";  # Pure white
    };

    # ══════════════════════════════════════════════════════════════════════════
    # Catppuccin Mocha - The cozy alternative
    # ══════════════════════════════════════════════════════════════════════════
    catppuccin = {
      name = "Catppuccin";
      bg = "#11111B";
      bgAlt = "#181825";
      surface = "#1E1E2E";
      surfaceAlt = "#313244";
      overlay = "#45475A";
      border = "#45475A";
      borderFocus = "#CBA6F7";
      borderHover = "#F5C2E7";
      accent = "#CBA6F7";
      accentAlt = "#F5C2E7";
      accentDim = "#B4A0E5";
      gradientStart = "#CBA6F7";
      gradientEnd = "#F5C2E7";
      gradientAngle = "45deg";
      text = "#CDD6F4";
      textAlt = "#BAC2DE";
      textDim = "#6C7086";
      textOnAccent = "#11111B";
      success = "#A6E3A1";
      warning = "#F9E2AF";
      error = "#F38BA8";
      info = "#89DCEB";
      purple = "#CBA6F7";
      pink = "#F5C2E7";
      orange = "#FAB387";
      yellow = "#F9E2AF";
      cyan = "#89DCEB";
      green = "#A6E3A1";
      black = "#11111B";
      brightBlack = "#45475A";
      red = "#F38BA8";
      brightRed = "#F5A0B8";
      brightGreen = "#B8EBB3";
      brightYellow = "#FBE9C0";
      blue = "#89B4FA";
      brightBlue = "#A0C4FC";
      magenta = "#CBA6F7";
      brightMagenta = "#DDB8F9";
      brightCyan = "#A0E8F5";
      white = "#CDD6F4";
      brightWhite = "#FFFFFF";
    };

    # ══════════════════════════════════════════════════════════════════════════
    # Nord - Frozen and calm
    # ══════════════════════════════════════════════════════════════════════════
    nord = {
      name = "Nord";
      bg = "#242933";
      bgAlt = "#2E3440";
      surface = "#3B4252";
      surfaceAlt = "#434C5E";
      overlay = "#4C566A";
      border = "#4C566A";
      borderFocus = "#88C0D0";
      borderHover = "#81A1C1";
      accent = "#88C0D0";
      accentAlt = "#81A1C1";
      accentDim = "#5E81AC";
      gradientStart = "#88C0D0";
      gradientEnd = "#81A1C1";
      gradientAngle = "45deg";
      text = "#ECEFF4";
      textAlt = "#E5E9F0";
      textDim = "#D8DEE9";
      textOnAccent = "#2E3440";
      success = "#A3BE8C";
      warning = "#EBCB8B";
      error = "#BF616A";
      info = "#81A1C1";
      purple = "#B48EAD";
      pink = "#B48EAD";
      orange = "#D08770";
      yellow = "#EBCB8B";
      cyan = "#88C0D0";
      green = "#A3BE8C";
      black = "#2E3440";
      brightBlack = "#4C566A";
      red = "#BF616A";
      brightRed = "#D08770";
      brightGreen = "#B5CEA0";
      brightYellow = "#F0D9A0";
      blue = "#81A1C1";
      brightBlue = "#88C0D0";
      magenta = "#B48EAD";
      brightMagenta = "#C6A0BF";
      brightCyan = "#8FBCBB";
      white = "#E5E9F0";
      brightWhite = "#ECEFF4";
    };

    # ══════════════════════════════════════════════════════════════════════════
    # Rosé Pine - Elegant and muted
    # ══════════════════════════════════════════════════════════════════════════
    rosepine = {
      name = "Rosé Pine";
      bg = "#191724";
      bgAlt = "#1F1D2E";
      surface = "#26233A";
      surfaceAlt = "#2A273F";
      overlay = "#393552";
      border = "#403D52";
      borderFocus = "#C4A7E7";
      borderHover = "#EBBCBA";
      accent = "#C4A7E7";
      accentAlt = "#EBBCBA";
      accentDim = "#9C8EC4";
      gradientStart = "#C4A7E7";
      gradientEnd = "#EBBCBA";
      gradientAngle = "45deg";
      text = "#E0DEF4";
      textAlt = "#908CAA";
      textDim = "#6E6A86";
      textOnAccent = "#191724";
      success = "#9CCFD8";
      warning = "#F6C177";
      error = "#EB6F92";
      info = "#31748F";
      purple = "#C4A7E7";
      pink = "#EBBCBA";
      orange = "#F6C177";
      yellow = "#F6C177";
      cyan = "#9CCFD8";
      green = "#9CCFD8";
      black = "#191724";
      brightBlack = "#403D52";
      red = "#EB6F92";
      brightRed = "#F0A0B0";
      brightGreen = "#B0DFE5";
      brightYellow = "#F9D5A0";
      blue = "#31748F";
      brightBlue = "#5A99AD";
      magenta = "#C4A7E7";
      brightMagenta = "#D4BFEF";
      brightCyan = "#B0DFE5";
      white = "#E0DEF4";
      brightWhite = "#FFFFFF";
    };

    # ══════════════════════════════════════════════════════════════════════════
    # Dracula - Classic dark with purple flair
    # ══════════════════════════════════════════════════════════════════════════
    dracula = {
      name = "Dracula";
      bg = "#1E1F29";
      bgAlt = "#282A36";
      surface = "#343746";
      surfaceAlt = "#44475A";
      overlay = "#4D4F68";
      border = "#44475A";
      borderFocus = "#BD93F9";
      borderHover = "#FF79C6";
      accent = "#BD93F9";
      accentAlt = "#FF79C6";
      accentDim = "#9B7AD6";
      gradientStart = "#BD93F9";
      gradientEnd = "#FF79C6";
      gradientAngle = "45deg";
      text = "#F8F8F2";
      textAlt = "#BFBFBF";
      textDim = "#6272A4";
      textOnAccent = "#282A36";
      success = "#50FA7B";
      warning = "#F1FA8C";
      error = "#FF5555";
      info = "#8BE9FD";
      purple = "#BD93F9";
      pink = "#FF79C6";
      orange = "#FFB86C";
      yellow = "#F1FA8C";
      cyan = "#8BE9FD";
      green = "#50FA7B";
      black = "#282A36";
      brightBlack = "#44475A";
      red = "#FF5555";
      brightRed = "#FF6E6E";
      brightGreen = "#69FF94";
      brightYellow = "#F4FCA0";
      blue = "#8BE9FD";
      brightBlue = "#A4EFFF";
      magenta = "#FF79C6";
      brightMagenta = "#FF92D0";
      brightCyan = "#A4EFFF";
      white = "#F8F8F2";
      brightWhite = "#FFFFFF";
    };

    # ══════════════════════════════════════════════════════════════════════════
    # Gruvbox - Warm and earthy
    # ══════════════════════════════════════════════════════════════════════════
    gruvbox = {
      name = "Gruvbox";
      bg = "#1D2021";
      bgAlt = "#282828";
      surface = "#32302F";
      surfaceAlt = "#3C3836";
      overlay = "#504945";
      border = "#504945";
      borderFocus = "#D79921";
      borderHover = "#FABD2F";
      accent = "#D79921";
      accentAlt = "#FABD2F";
      accentDim = "#B57614";
      gradientStart = "#D79921";
      gradientEnd = "#FABD2F";
      gradientAngle = "45deg";
      text = "#EBDBB2";
      textAlt = "#D5C4A1";
      textDim = "#928374";
      textOnAccent = "#282828";
      success = "#B8BB26";
      warning = "#FABD2F";
      error = "#FB4934";
      info = "#83A598";
      purple = "#D3869B";
      pink = "#D3869B";
      orange = "#FE8019";
      yellow = "#FABD2F";
      cyan = "#8EC07C";
      green = "#B8BB26";
      black = "#282828";
      brightBlack = "#504945";
      red = "#FB4934";
      brightRed = "#FE8019";
      brightGreen = "#98971A";
      brightYellow = "#FCE566";
      blue = "#83A598";
      brightBlue = "#458588";
      magenta = "#D3869B";
      brightMagenta = "#B16286";
      brightCyan = "#689D6A";
      white = "#EBDBB2";
      brightWhite = "#FBF1C7";
    };

    # ══════════════════════════════════════════════════════════════════════════
    # Tokyo Night - Modern with Japanese aesthetics
    # ══════════════════════════════════════════════════════════════════════════
    tokyo = {
      name = "Tokyo Night";
      bg = "#16161E";
      bgAlt = "#1A1B26";
      surface = "#24283B";
      surfaceAlt = "#292E42";
      overlay = "#343A52";
      border = "#3B4261";
      borderFocus = "#7AA2F7";
      borderHover = "#BB9AF7";
      accent = "#7AA2F7";
      accentAlt = "#BB9AF7";
      accentDim = "#5A7DD6";
      gradientStart = "#7AA2F7";
      gradientEnd = "#BB9AF7";
      gradientAngle = "45deg";
      text = "#C0CAF5";
      textAlt = "#A9B1D6";
      textDim = "#565F89";
      textOnAccent = "#1A1B26";
      success = "#9ECE6A";
      warning = "#E0AF68";
      error = "#F7768E";
      info = "#7DCFFF";
      purple = "#BB9AF7";
      pink = "#FF007C";
      orange = "#FF9E64";
      yellow = "#E0AF68";
      cyan = "#7DCFFF";
      green = "#9ECE6A";
      black = "#1A1B26";
      brightBlack = "#414868";
      red = "#F7768E";
      brightRed = "#FF899D";
      brightGreen = "#B2DC82";
      brightYellow = "#ECC580";
      blue = "#7AA2F7";
      brightBlue = "#8CB4F9";
      magenta = "#BB9AF7";
      brightMagenta = "#CDACF9";
      brightCyan = "#91D9FF";
      white = "#C0CAF5";
      brightWhite = "#FFFFFF";
    };

    # ══════════════════════════════════════════════════════════════════════════
    # Phosphor - Maximum retro terminal energy
    # ══════════════════════════════════════════════════════════════════════════
    phosphor = {
      name = "Phosphor";
      bg = "#0A0A0A";           # Pure CRT black
      bgAlt = "#0D0D0D";
      surface = "#141414";
      surfaceAlt = "#1A1A1A";
      overlay = "#222222";
      border = "#2A2A2A";
      borderFocus = "#39FF14";  # Classic green phosphor
      borderHover = "#00FF88";
      accent = "#39FF14";       # THE green
      accentAlt = "#32CD32";
      accentDim = "#228B22";
      gradientStart = "#39FF14";
      gradientEnd = "#00FF88";
      gradientAngle = "180deg"; # Vertical scan line style
      text = "#33FF33";         # Green text like old terminals
      textAlt = "#22CC22";
      textDim = "#117711";
      textOnAccent = "#0A0A0A";
      success = "#39FF14";
      warning = "#FFFF00";      # Amber warning
      error = "#FF0040";
      info = "#39FF14";
      purple = "#9D00FF";
      pink = "#FF00FF";
      orange = "#FF8800";
      yellow = "#FFFF00";
      cyan = "#00FFFF";
      green = "#39FF14";
      black = "#0A0A0A";
      brightBlack = "#333333";
      red = "#FF0040";
      brightRed = "#FF3366";
      brightGreen = "#69FF4D";
      brightYellow = "#FFFF66";
      blue = "#00AAFF";
      brightBlue = "#00DDFF";
      magenta = "#FF00FF";
      brightMagenta = "#FF66FF";
      brightCyan = "#66FFFF";
      white = "#33FF33";
      brightWhite = "#66FF66";
    };
  };

  # Default palette - change this to set your preferred default
  defaultPalette = "demod";
  p = palettes.${defaultPalette};

  # ──────────────────────────────────────────────────────────────────────────────
  # Feature Flags
  # ──────────────────────────────────────────────────────────────────────────────
  features = {
    hasBattery = true;
    hasBluetooth = true;
    hasBacklight = true;
    hasTouchpad = true;
    enableDCF = true;
    enableAIStack = true;
    enableGaming = true;
    enableDev = true;
  };

  # Monitor config
  monitors = {
    laptop = { name = "eDP-1"; resolution = "2560x1600@165"; position = "0x0"; scale = "1"; };
  };

  # Waybar modules helper
  mkWaybarModules = {
    left = [ "custom/logo" "hyprland/workspaces" "hyprland/submap" "custom/separator-left" "hyprland/window" ];
    center = [ "custom/separator-dot" "clock" "custom/separator-dot" ];
    right = lib.flatten [
      [ "custom/media" ]
      [ "custom/separator-right" "group/audio" ]
      [ "custom/separator-right" "group/network" ]
      [ "custom/separator-right" "group/system" ]
      (lib.optionals features.hasBattery [ "custom/separator-right" "battery" ])
      [ "custom/separator-right" "tray" ]
      [ "custom/power" ]
    ];
  };

in {
  home.username = username;
  home.homeDirectory = homeDirectory;
  home.stateVersion = "24.11";
  programs.home-manager.enable = true;

  # ════════════════════════════════════════════════════════════════════════════
  # Cursor
  # ════════════════════════════════════════════════════════════════════════════
  home.pointerCursor = {
    gtk.enable = true;
    x11.enable = true;
    package = pkgs.bibata-cursors;
    name = "Bibata-Modern-Classic";
    size = 24;
  };

  fonts.fontconfig.enable = true;

  # ════════════════════════════════════════════════════════════════════════════
  # Packages
  # ════════════════════════════════════════════════════════════════════════════
  home.packages = with pkgs; lib.flatten [
    # Fonts
    [ jetbrains-mono nerd-fonts.jetbrains-mono font-awesome noto-fonts noto-fonts-color-emoji inter ]

    # Hyprland
    [ hyprpaper hypridle hyprlock hyprpicker ]

    # Utils
    [ grim slurp swappy cliphist wl-clipboard jq ripgrep fd eza bat fzf libnotify wtype wlr-randr xdg-utils lm_sensors ]

    # System
    [ udiskie polkit_gnome networkmanagerapplet ]
    (lib.optional features.hasBluetooth blueman)

    # UI - Launchers & Theming
    [ wofi wlogout ]
    
    # Qt/KDE Theming
    [
      libsForQt5.qt5ct
      kdePackages.qt6ct
      libsForQt5.qtstyleplugin-kvantum
      kdePackages.qtstyleplugin-kvantum  # Qt6 Kvantum
      papirus-icon-theme
      bibata-cursors
      adwaita-qt
      adwaita-qt6
    ]

    # Apps
    [ brave xfce.thunar xfce.tumbler vlc gnome-calculator gnome-system-monitor ]
    (lib.optionals features.enableDev [ vscode-fhs obsidian git gh lazygit btop ])
    (lib.optionals features.enableGaming [ steam ])
    [ thunderbird libreoffice-qt6-fresh ]

    # Media
    [ wireplumber pavucontrol playerctl easyeffects helvum ]
    (lib.optional features.hasBacklight brightnessctl)
    [ gpu-screen-recorder imagemagick ffmpeg gnome-keyring ]
  ];

  # ════════════════════════════════════════════════════════════════════════════
  # XDG
  # ════════════════════════════════════════════════════════════════════════════
  xdg = {
    enable = true;
    userDirs = {
      enable = true;
      createDirectories = true;
      desktop = "${homeDirectory}/Desktop";
      documents = "${homeDirectory}/Documents";
      download = "${homeDirectory}/Downloads";
      music = "${homeDirectory}/Music";
      pictures = "${homeDirectory}/Pictures";
      videos = "${homeDirectory}/Videos";
      extraConfig = { XDG_SCREENSHOTS_DIR = "${homeDirectory}/Pictures/Screenshots"; };
    };
    portal = {
      enable = true;
      extraPortals = [ pkgs.xdg-desktop-portal-hyprland pkgs.xdg-desktop-portal-gtk ];
      config.common.default = [ "hyprland" "gtk" ];
    };
  };

  # ════════════════════════════════════════════════════════════════════════════
  # KDE Plasma 6 Theming - DeMoD Dark
  # ════════════════════════════════════════════════════════════════════════════
  # Complete Plasma theming with white-on-black and turquoise/violet accents
  
  # Main KDE Global Settings & Color Scheme
  home.file.".config/kdeglobals".text = ''
    [General]
    ColorScheme=DeMoDDark
    Name=DeMoD Dark
    shadeSortColumn=true
    
    [ColorEffects:Disabled]
    Color=56,56,56
    ColorAmount=0
    ColorEffect=0
    ContrastAmount=0.65
    ContrastEffect=1
    IntensityAmount=0.1
    IntensityEffect=2
    
    [ColorEffects:Inactive]
    ChangeSelectionColor=true
    Color=112,111,110
    ColorAmount=0.025
    ColorEffect=2
    ContrastAmount=0.1
    ContrastEffect=2
    Enable=false
    IntensityAmount=0
    IntensityEffect=0
    
    [Colors:Button]
    BackgroundAlternate=16,16,24
    BackgroundNormal=16,16,32
    DecorationFocus=0,245,212
    DecorationHover=139,92,246
    ForegroundActive=0,245,212
    ForegroundInactive=128,128,128
    ForegroundLink=0,245,212
    ForegroundNegative=255,59,92
    ForegroundNeutral=255,232,20
    ForegroundNormal=255,255,255
    ForegroundPositive=57,255,20
    ForegroundVisited=167,139,250
    
    [Colors:Complementary]
    BackgroundAlternate=8,8,16
    BackgroundNormal=8,8,16
    DecorationFocus=0,245,212
    DecorationHover=139,92,246
    ForegroundActive=0,245,212
    ForegroundInactive=128,128,128
    ForegroundLink=0,245,212
    ForegroundNegative=255,59,92
    ForegroundNeutral=255,232,20
    ForegroundNormal=255,255,255
    ForegroundPositive=57,255,20
    ForegroundVisited=167,139,250
    
    [Colors:Header]
    BackgroundAlternate=12,12,20
    BackgroundNormal=8,8,16
    DecorationFocus=0,245,212
    DecorationHover=139,92,246
    ForegroundActive=0,245,212
    ForegroundInactive=128,128,128
    ForegroundLink=0,245,212
    ForegroundNegative=255,59,92
    ForegroundNeutral=255,232,20
    ForegroundNormal=255,255,255
    ForegroundPositive=57,255,20
    ForegroundVisited=167,139,250
    
    [Colors:Selection]
    BackgroundAlternate=0,200,170
    BackgroundNormal=0,245,212
    DecorationFocus=0,245,212
    DecorationHover=139,92,246
    ForegroundActive=8,8,16
    ForegroundInactive=8,8,16
    ForegroundLink=8,8,16
    ForegroundNegative=180,40,60
    ForegroundNeutral=180,160,0
    ForegroundNormal=8,8,16
    ForegroundPositive=30,120,10
    ForegroundVisited=80,60,140
    
    [Colors:Tooltip]
    BackgroundAlternate=16,16,24
    BackgroundNormal=12,12,20
    DecorationFocus=0,245,212
    DecorationHover=139,92,246
    ForegroundActive=0,245,212
    ForegroundInactive=128,128,128
    ForegroundLink=0,245,212
    ForegroundNegative=255,59,92
    ForegroundNeutral=255,232,20
    ForegroundNormal=255,255,255
    ForegroundPositive=57,255,20
    ForegroundVisited=167,139,250
    
    [Colors:View]
    BackgroundAlternate=12,12,20
    BackgroundNormal=8,8,16
    DecorationFocus=0,245,212
    DecorationHover=139,92,246
    ForegroundActive=0,245,212
    ForegroundInactive=128,128,128
    ForegroundLink=0,245,212
    ForegroundNegative=255,59,92
    ForegroundNeutral=255,232,20
    ForegroundNormal=255,255,255
    ForegroundPositive=57,255,20
    ForegroundVisited=167,139,250
    
    [Colors:Window]
    BackgroundAlternate=12,12,20
    BackgroundNormal=8,8,16
    DecorationFocus=0,245,212
    DecorationHover=139,92,246
    ForegroundActive=0,245,212
    ForegroundInactive=128,128,128
    ForegroundLink=0,245,212
    ForegroundNegative=255,59,92
    ForegroundNeutral=255,232,20
    ForegroundNormal=255,255,255
    ForegroundPositive=57,255,20
    ForegroundVisited=167,139,250
    
    [Icons]
    Theme=Papirus-Dark
    
    [KDE]
    AnimationDurationFactor=0.5
    ShowDeleteCommand=true
    SingleClick=false
    contrast=4
    widgetStyle=kvantum
    
    [KFileDialog Settings]
    Allow Expansion=false
    Automatically select filename extension=true
    Breadcrumb Navigation=true
    Decoration position=2
    LocationCombo Coverage=
    Preview Width=80
    Show Bookmarks=true
    Show Full Path=false
    Show Preview=false
    Show Speedbar=true
    Show hidden files=false
    Sort by=Name
    Sort directories first=true
    Sort hidden files last=false
    Sort reversed=false
    Speedbar Width=130
    View Style=DetailTree
    
    [WM]
    activeBackground=8,8,16
    activeBlend=0,245,212
    activeForeground=255,255,255
    inactiveBackground=8,8,16
    inactiveBlend=64,64,80
    inactiveForeground=128,128,128
  '';

  # KWin Window Manager Settings
  home.file.".config/kwinrc".text = ''
    [Compositing]
    AnimationCurve=1
    AnimationSpeed=3
    Backend=OpenGL
    Enabled=true
    GLCore=true
    GLPreferBufferSwap=a
    GLTextureFilter=2
    HiddenPreviews=5
    OpenGLIsUnsafe=false
    WindowsBlockCompositing=true
    
    [Effect-blur]
    BlurStrength=8
    NoiseStrength=4
    
    [Effect-overview]
    BorderActivate=9
    
    [Effect-windowview]
    BorderActivateAll=9
    
    [Plugins]
    blurEnabled=true
    contrastEnabled=true
    dimscreenEnabled=true
    fadeEnabled=true
    glideEnabled=false
    kwin4_effect_diminavtiveEnabled=true
    kwin4_effect_squashEnabled=false
    magiclampEnabled=false
    scaleEnabled=true
    slideEnabled=true
    
    [TabBox]
    BorderActivate=9
    BorderAlternativeActivate=9
    LayoutName=thumbnail_grid
    
    [Tiling]
    padding=4
    
    [Windows]
    BorderlessMaximizedWindows=false
    ElectricBorderCooldown=350
    ElectricBorderCornerRatio=0.25
    ElectricBorderDelay=150
    ElectricBorderMaximize=true
    ElectricBorderTiling=true
    ElectricBorders=0
    FocusPolicy=ClickToFocus
    FocusStealingPreventionLevel=1
    
    [org.kde.kdecoration2]
    BorderSize=Normal
    BorderSizeAuto=false
    ButtonsOnLeft=XIA
    ButtonsOnRight=
    CloseOnDoubleClickOnMenu=false
    library=org.kde.breeze
    theme=Breeze
  '';

  # Plasma Shell Settings
  home.file.".config/plasmarc".text = ''
    [Theme]
    name=breeze-dark
    
    [Wallpapers]
    usersWallpapers=
  '';

  # Plasma Desktop Appearance
  home.file.".config/plasma-org.kde.plasma.desktop-appletsrc".text = lib.mkDefault "";

  # Kvantum Theme Configuration (Qt theming engine)
  home.file.".config/Kvantum/kvantum.kvconfig".text = ''
    [General]
    theme=KvArcDark
  '';

  # Custom Kvantum theme for DeMoD
  home.file.".config/Kvantum/DeMoD/DeMoD.kvconfig".text = ''
    [%General]
    author=DeMoD
    comment=DeMoD Dark Theme - Turquoise/Violet on Black
    x11drag=menubar_and_primary_toolbar
    alt_mnemonic=true
    left_tabs=false
    attach_active_tab=true
    mirror_doc_tabs=false
    group_toolbar_buttons=false
    toolbar_item_spacing=2
    toolbar_interior_spacing=2
    spread_progressbar=true
    composite=true
    menu_shadow_depth=7
    spread_menuitems=true
    tooltip_shadow_depth=6
    splitter_width=1
    scroll_width=12
    scroll_arrows=false
    scroll_min_extent=36
    slider_width=4
    slider_handle_width=18
    slider_handle_length=18
    tickless_slider_handle_size=18
    center_toolbar_handle=true
    check_size=16
    textless_progressbar=false
    progressbar_thickness=4
    menubar_mouse_tracking=true
    toolbutton_style=0
    click_behavior=0
    translucent_windows=true
    blurring=true
    popup_blurring=true
    vertical_spin_indicators=false
    spin_button_width=16
    fill_rubberband=false
    merge_menubar_with_toolbar=false
    small_icon_size=16
    large_icon_size=32
    button_icon_size=16
    toolbar_icon_size=22
    combo_as_lineedit=true
    button_contents_shift=false
    iconless_pushbutton=false
    iconless_menu=false
    scrollbar_in_view=false
    transient_scrollbar=true
    transient_groove=true
    dark_titlebar=true
    respect_DE=true
    
    [GeneralColors]
    window.color=#080810
    base.color=#0C0C14
    alt.base.color=#101018
    button.color=#161620
    light.color=#252530
    mid.light.color=#1C1C28
    dark.color=#040408
    mid.color=#101018
    highlight.color=#00F5D4
    inactive.highlight.color=#8B5CF6
    text.color=#FFFFFF
    window.text.color=#FFFFFF
    button.text.color=#FFFFFF
    disabled.text.color=#808080
    tooltip.text.color=#FFFFFF
    highlight.text.color=#080810
    link.color=#00F5D4
    link.visited.color=#A78BFA
    progress.indicator.text.color=#080810
    
    [Hacks]
    transparent_dolphin_view=false
    transparent_pcmanfm_sidepane=true
    transparent_pcmanfm_view=false
    blur_translucent=true
    transparent_ktitle_label=true
    transparent_menutitle=true
    respect_darkness=true
    kcapacitybar_as_progressbar=true
    force_size_grip=true
    iconless_pushbutton=false
    iconless_menu=false
    disabled_icon_opacity=70
    lxqtmainmenu_iconsize=22
    normal_default_pushbutton=true
    single_top_toolbar=false
    tint_on_mouseover=0
    middle_click_scroll=false
    no_selection_tint=false
    transparent_arrow_button=true
    style_vertical_toolbars=false
  '';

  home.file.".config/Kvantum/DeMoD/DeMoD.svg".text = ''
    <?xml version="1.0" encoding="UTF-8"?>
    <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 100 100">
      <!-- DeMoD Kvantum Theme Base -->
      <defs>
        <linearGradient id="accentGrad" x1="0%" y1="0%" x2="100%" y2="100%">
          <stop offset="0%" style="stop-color:#00F5D4"/>
          <stop offset="100%" style="stop-color:#8B5CF6"/>
        </linearGradient>
      </defs>
    </svg>
  '';

  # GTK 3 Settings
  home.file.".config/gtk-3.0/settings.ini".text = ''
    [Settings]
    gtk-application-prefer-dark-theme=true
    gtk-button-images=true
    gtk-cursor-theme-name=Bibata-Modern-Classic
    gtk-cursor-theme-size=24
    gtk-decoration-layout=close,minimize,maximize:menu
    gtk-enable-animations=true
    gtk-enable-event-sounds=false
    gtk-enable-input-feedback-sounds=false
    gtk-error-bell=false
    gtk-font-name=Inter 10
    gtk-icon-theme-name=Papirus-Dark
    gtk-menu-images=true
    gtk-primary-button-warps-slider=false
    gtk-theme-name=Breeze-Dark
    gtk-toolbar-icon-size=GTK_ICON_SIZE_LARGE_TOOLBAR
    gtk-toolbar-style=GTK_TOOLBAR_BOTH_HORIZ
    gtk-xft-antialias=1
    gtk-xft-dpi=98304
    gtk-xft-hinting=1
    gtk-xft-hintstyle=hintslight
    gtk-xft-rgba=rgb
  '';

  # GTK 3 Custom CSS
  home.file.".config/gtk-3.0/gtk.css".text = ''
    /* DeMoD GTK3 Overrides - Enhanced UX per Design System */
    @define-color theme_bg_color #080810;
    @define-color theme_fg_color #FFFFFF;
    @define-color theme_base_color #0C0C14;
    @define-color theme_text_color #FFFFFF;
    @define-color theme_selected_bg_color #00F5D4;
    @define-color theme_selected_fg_color #080810;
    @define-color theme_tooltip_bg_color #101018;
    @define-color theme_tooltip_fg_color #FFFFFF;
    @define-color accent_color #00F5D4;
    @define-color accent_bg_color #00F5D4;
    @define-color accent_fg_color #080810;
    
    /* ── Scrollbars ─────────────────────────────────────────────────────────── */
    scrollbar slider {
      min-width: 8px;
      min-height: 8px;
      border-radius: 4px;
      background-color: alpha(#00F5D4, 0.4);
      transition: all 0.15s ease;
    }
    
    scrollbar slider:hover {
      background-color: alpha(#00F5D4, 0.6);
    }
    
    scrollbar slider:active {
      background-color: #00F5D4;
    }
    
    /* ── Selection ──────────────────────────────────────────────────────────── */
    selection, *:selected {
      background-color: #00F5D4;
      color: #080810;
    }
    
    /* ── Links ──────────────────────────────────────────────────────────────── */
    *:link {
      color: #00F5D4;
      transition: color 0.15s ease;
    }
    
    *:visited {
      color: #A78BFA;
    }
    
    *:link:hover {
      color: #8B5CF6;
    }
    
    /* ── Buttons ────────────────────────────────────────────────────────────── */
    button {
      transition: all 0.2s ease;
    }
    
    button:checked {
      background-image: linear-gradient(135deg, #00F5D4, #8B5CF6);
      color: #080810;
    }
    
    button:hover {
      box-shadow: 0 4px 12px rgba(0, 245, 212, 0.2);
    }
    
    button:focus {
      outline: none;
      box-shadow: 0 0 0 3px rgba(0, 245, 212, 0.3);
    }
    
    /* ── Entries/Inputs ─────────────────────────────────────────────────────── */
    entry {
      transition: all 0.2s ease;
      border-radius: 8px;
    }
    
    entry:focus {
      box-shadow: 0 0 0 3px rgba(0, 245, 212, 0.15);
    }
    
    /* ── Progress bars ──────────────────────────────────────────────────────── */
    progressbar progress {
      background-image: linear-gradient(135deg, #00F5D4, #8B5CF6);
      border-radius: 4px;
    }
    
    /* ── Switches ───────────────────────────────────────────────────────────── */
    switch {
      transition: all 0.25s ease;
    }
    
    switch:checked {
      background-image: linear-gradient(135deg, #00F5D4, #8B5CF6);
    }
    
    switch:checked slider {
      background-color: #FFFFFF;
    }
    
    /* ── Scale/Sliders ──────────────────────────────────────────────────────── */
    scale highlight {
      background-image: linear-gradient(135deg, #00F5D4, #8B5CF6);
    }
    
    scale slider {
      background-color: #FFFFFF;
    }
    
    /* ── Checkboxes & Radio ─────────────────────────────────────────────────── */
    checkbutton check:checked,
    radiobutton radio:checked {
      background-image: linear-gradient(135deg, #00F5D4, #8B5CF6);
      color: #080810;
    }
    
    /* ── Reduced Motion Support ─────────────────────────────────────────────── */
    @media (prefers-reduced-motion: reduce) {
      * {
        transition-duration: 0.01ms !important;
        animation-duration: 0.01ms !important;
        animation-iteration-count: 1 !important;
      }
    }
  '';

  # GTK 4 Settings
  home.file.".config/gtk-4.0/settings.ini".text = ''
    [Settings]
    gtk-application-prefer-dark-theme=true
    gtk-cursor-theme-name=Bibata-Modern-Classic
    gtk-cursor-theme-size=24
    gtk-decoration-layout=close,minimize,maximize:menu
    gtk-enable-animations=true
    gtk-font-name=Inter 10
    gtk-icon-theme-name=Papirus-Dark
    gtk-theme-name=Adwaita-dark
    gtk-xft-antialias=1
    gtk-xft-hinting=1
    gtk-xft-hintstyle=hintslight
    gtk-xft-rgba=rgb
  '';

  # GTK 4 Custom CSS
  home.file.".config/gtk-4.0/gtk.css".text = ''
    /* DeMoD GTK4 Overrides - Enhanced UX per Design System */
    @define-color window_bg_color #080810;
    @define-color window_fg_color #FFFFFF;
    @define-color view_bg_color #0C0C14;
    @define-color view_fg_color #FFFFFF;
    @define-color card_bg_color #101018;
    @define-color card_fg_color #FFFFFF;
    @define-color headerbar_bg_color #080810;
    @define-color headerbar_fg_color #FFFFFF;
    @define-color popover_bg_color #101018;
    @define-color popover_fg_color #FFFFFF;
    @define-color dialog_bg_color #101018;
    @define-color dialog_fg_color #FFFFFF;
    @define-color sidebar_bg_color #0C0C14;
    @define-color sidebar_fg_color #FFFFFF;
    @define-color accent_color #00F5D4;
    @define-color accent_bg_color #00F5D4;
    @define-color accent_fg_color #080810;
    @define-color destructive_color #FF3B5C;
    @define-color success_color #39FF14;
    @define-color warning_color #FFE814;
    @define-color error_color #FF3B5C;
    
    /* ── Global Selection ───────────────────────────────────────────────────── */
    selection {
      background-color: #00F5D4;
      color: #080810;
    }
    
    /* ── Accent Elements ────────────────────────────────────────────────────── */
    .accent {
      color: #00F5D4;
    }
    
    /* ── Buttons ────────────────────────────────────────────────────────────── */
    button {
      transition: all 0.2s ease;
    }
    
    button:hover {
      box-shadow: 0 4px 12px rgba(0, 245, 212, 0.15);
    }
    
    button:focus {
      outline: none;
      box-shadow: 0 0 0 3px rgba(0, 245, 212, 0.3);
    }
    
    button.suggested-action {
      background-image: linear-gradient(135deg, #00F5D4, #8B5CF6);
      color: #080810;
      box-shadow: 0 4px 12px rgba(0, 245, 212, 0.3);
    }
    
    button.suggested-action:hover {
      background-image: linear-gradient(135deg, #00E5C7, #7C4DE8);
      box-shadow: 0 6px 20px rgba(0, 245, 212, 0.4);
    }
    
    button.destructive-action {
      background-color: #FF3B5C;
      color: #FFFFFF;
    }
    
    button.destructive-action:hover {
      background-color: #E62E4D;
      box-shadow: 0 4px 12px rgba(255, 59, 92, 0.3);
    }
    
    /* ── Entries/Inputs ─────────────────────────────────────────────────────── */
    entry {
      transition: all 0.2s ease;
      border-radius: 12px;
    }
    
    entry:focus {
      box-shadow: 0 0 0 3px rgba(0, 245, 212, 0.15);
    }
    
    /* ── Progress bars ──────────────────────────────────────────────────────── */
    progressbar > trough > progress {
      background-image: linear-gradient(135deg, #00F5D4, #8B5CF6);
    }
    
    /* ── Switches ───────────────────────────────────────────────────────────── */
    switch {
      transition: all 0.25s ease;
    }
    
    switch:checked {
      background-image: linear-gradient(135deg, #00F5D4, #8B5CF6);
    }
    
    /* ── Scale/Slider ───────────────────────────────────────────────────────── */
    scale highlight {
      background-image: linear-gradient(135deg, #00F5D4, #8B5CF6);
    }
    
    scale slider {
      background-color: #FFFFFF;
    }
    
    /* ── Links ──────────────────────────────────────────────────────────────── */
    link, .link {
      color: #00F5D4;
      transition: color 0.15s ease;
    }
    
    link:visited, .link:visited {
      color: #A78BFA;
    }
    
    link:hover, .link:hover {
      color: #8B5CF6;
    }
    
    /* ── Scrollbars ─────────────────────────────────────────────────────────── */
    scrollbar slider {
      background-color: alpha(#00F5D4, 0.4);
      border-radius: 9999px;
      min-width: 8px;
      min-height: 8px;
      transition: all 0.15s ease;
    }
    
    scrollbar slider:hover {
      background-color: alpha(#00F5D4, 0.6);
    }
    
    scrollbar slider:active {
      background-color: #00F5D4;
    }
    
    /* ── Check and Radio Buttons ────────────────────────────────────────────── */
    checkbutton check:checked,
    radiobutton radio:checked {
      background-image: linear-gradient(135deg, #00F5D4, #8B5CF6);
      color: #080810;
    }
    
    checkbutton check:focus,
    radiobutton radio:focus {
      box-shadow: 0 0 0 3px rgba(0, 245, 212, 0.3);
    }
    
    /* ── Headerbar ──────────────────────────────────────────────────────────── */
    headerbar {
      background-color: #080810;
      border-bottom: 1px solid #252530;
    }
    
    /* ── Window Controls ────────────────────────────────────────────────────── */
    windowcontrols button.close:hover {
      background-color: #FF3B5C;
    }
    
    windowcontrols button.minimize:hover,
    windowcontrols button.maximize:hover {
      background-color: rgba(255, 255, 255, 0.1);
    }
    
    /* ── Cards ──────────────────────────────────────────────────────────────── */
    .card {
      background-color: #101018;
      border: 1px solid #252530;
      border-radius: 16px;
      box-shadow: 0 4px 16px rgba(0, 0, 0, 0.4);
      transition: all 0.2s ease;
    }
    
    .card:hover {
      border-color: #8B5CF6;
    }
    
    /* ── Reduced Motion Support ─────────────────────────────────────────────── */
    @media (prefers-reduced-motion: reduce) {
      * {
        transition-duration: 0.01ms !important;
        animation-duration: 0.01ms !important;
        animation-iteration-count: 1 !important;
      }
    }
  '';

  # Qt5/Qt6 Platform Theme Configuration  
  home.file.".config/qt5ct/qt5ct.conf".text = ''
    [Appearance]
    color_scheme_path=
    custom_palette=true
    icon_theme=Papirus-Dark
    standard_dialogs=default
    style=kvantum
    
    [Fonts]
    fixed="JetBrains Mono,10,-1,5,50,0,0,0,0,0"
    general="Inter,10,-1,5,50,0,0,0,0,0"
    
    [Interface]
    activate_item_on_single_click=1
    buttonbox_layout=0
    cursor_flash_time=1000
    dialog_buttons_have_icons=1
    double_click_interval=400
    gui_effects=@Invalid()
    keyboard_scheme=2
    menus_have_icons=true
    show_shortcuts_in_context_menus=true
    stylesheets=@Invalid()
    toolbutton_style=4
    underline_shortcut=1
    wheel_scroll_lines=3
    
    [PaletteEditor]
    geometry=@ByteArray()
    
    [SettingsWindow]
    geometry=@ByteArray()
  '';

  home.file.".config/qt6ct/qt6ct.conf".text = ''
    [Appearance]
    color_scheme_path=
    custom_palette=true
    icon_theme=Papirus-Dark
    standard_dialogs=default
    style=kvantum
    
    [Fonts]
    fixed="JetBrains Mono,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1"
    general="Inter,10,-1,5,400,0,0,0,0,0,0,0,0,0,0,1"
    
    [Interface]
    activate_item_on_single_click=1
    buttonbox_layout=0
    cursor_flash_time=1000
    dialog_buttons_have_icons=1
    double_click_interval=400
    gui_effects=@Invalid()
    keyboard_scheme=2
    menus_have_icons=true
    show_shortcuts_in_context_menus=true
    stylesheets=@Invalid()
    toolbutton_style=4
    underline_shortcut=1
    wheel_scroll_lines=3
  '';

  # Dolphin File Manager (if used)
  home.file.".config/dolphinrc".text = ''
    [General]
    EditableUrl=true
    GlobalViewProps=true
    RememberOpenedTabs=false
    ShowFullPath=true
    ShowFullPathInTitlebar=true
    ShowZoomSlider=false
    SortingChoice=CaseInsensitiveSorting
    Version=202
    ViewPropsTimestamp=2024,1,1,0,0,0
    
    [IconsMode]
    IconSize=48
    PreviewSize=48
    
    [KFileDialog Settings]
    Places Icons Auto-resize=false
    Places Icons Static Size=22
    
    [MainWindow]
    MenuBar=Disabled
    ToolBarsMovable=Disabled
    
    [PreviewSettings]
    Plugins=appimagethumbnail,audiothumbnail,blenderthumbnail,comicbookthumbnail,cursorthumbnail,djvuthumbnail,ebookthumbnail,exrthumbnail,directorythumbnail,fontthumbnail,imagethumbnail,jaborathumbnail,kraborathumbnail,opaborathumbnail,moaborathumbnail,windowsimagethumbnail,windowsexethumbnail
    
    [VersionControl]
    enabledPlugins=Git
  '';

  # Konsole Terminal Configuration (for KDE apps that use it)
  home.file.".local/share/konsole/DeMoD.colorscheme".text = ''
    [Background]
    Color=8,8,16
    
    [BackgroundFaint]
    Color=8,8,16
    
    [BackgroundIntense]
    Color=12,12,20
    
    [Color0]
    Color=8,8,16
    
    [Color0Faint]
    Color=8,8,16
    
    [Color0Intense]
    Color=64,64,80
    
    [Color1]
    Color=255,59,92
    
    [Color1Faint]
    Color=200,50,75
    
    [Color1Intense]
    Color=255,107,127
    
    [Color2]
    Color=57,255,20
    
    [Color2Faint]
    Color=45,200,16
    
    [Color2Intense]
    Color=105,255,77
    
    [Color3]
    Color=255,232,20
    
    [Color3Faint]
    Color=200,182,16
    
    [Color3Intense]
    Color=255,239,92
    
    [Color4]
    Color=0,180,216
    
    [Color4Faint]
    Color=0,140,170
    
    [Color4Intense]
    Color=0,245,212
    
    [Color5]
    Color=139,92,246
    
    [Color5Faint]
    Color=110,73,195
    
    [Color5Intense]
    Color=167,139,250
    
    [Color6]
    Color=0,245,212
    
    [Color6Faint]
    Color=0,190,165
    
    [Color6Intense]
    Color=92,255,232
    
    [Color7]
    Color=224,224,224
    
    [Color7Faint]
    Color=180,180,180
    
    [Color7Intense]
    Color=255,255,255
    
    [Foreground]
    Color=255,255,255
    
    [ForegroundFaint]
    Color=200,200,200
    
    [ForegroundIntense]
    Color=255,255,255
    
    [General]
    Anchor=0.5,0.5
    Blur=true
    ColorRandomization=false
    Description=DeMoD Dark
    FillStyle=Tile
    Opacity=0.95
    Wallpaper=
    WallpaperFlipType=NoFlip
    WallpaperOpacity=1
  '';

  home.file.".local/share/konsole/DeMoD.profile".text = ''
    [Appearance]
    ColorScheme=DeMoD
    Font=JetBrains Mono,11,-1,5,400,0,0,0,0,0,0,0,0,0,0,1
    UseFontLineChararacters=true
    
    [Cursor Options]
    CursorShape=1
    UseCustomCursorColor=true
    CustomCursorColor=0,245,212
    CustomCursorTextColor=8,8,16
    
    [General]
    Command=/run/current-system/sw/bin/bash
    Name=DeMoD
    Parent=FALLBACK/
    TerminalCenter=true
    TerminalMargin=12
    
    [Interaction Options]
    AutoCopySelectedText=true
    TrimLeadingSpacesInSelectedText=true
    TrimTrailingSpacesInSelectedText=true
    
    [Scrolling]
    HistoryMode=2
    ScrollBarPosition=2
    
    [Terminal Features]
    BlinkingCursorEnabled=true
    UrlHintsModifiers=67108864
  '';

  # Set Konsole as default profile
  home.file.".config/konsolerc".text = ''
    [Desktop Entry]
    DefaultProfile=DeMoD.profile
    
    [General]
    ConfigVersion=1
    
    [MainWindow]
    MenuBar=Disabled
    ToolBarsMovable=Disabled
    
    [TabBar]
    CloseTabOnMiddleMouseButton=true
    NewTabBehavior=PutNewTabAtTheEnd
    TabBarPosition=Top
    TabBarVisibility=ShowTabBarWhenNeeded
  '';

  # ════════════════════════════════════════════════════════════════════════════
  # Hyprland
  # ════════════════════════════════════════════════════════════════════════════
  wayland.windowManager.hyprland = {
    enable = true;
    settings = {
      monitor = [ "${monitors.laptop.name}, ${monitors.laptop.resolution}, ${monitors.laptop.position}, ${monitors.laptop.scale}" ", preferred, auto, 1" ];

      exec-once = lib.flatten [
        [ "waybar" "hyprpaper" "hypridle" "mako" ]
        [ "${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1" ]
        [ "${pkgs.gnome-keyring}/bin/gnome-keyring-daemon --start --components=secrets" ]
        [ "nm-applet --indicator" "udiskie --automount --notify" ]
        (lib.optional features.hasBluetooth "blueman-applet")
        [ "wl-paste --type text --watch cliphist store" "wl-paste --type image --watch cliphist store" ]
        (lib.optional features.enableDCF "dcf-tray")
        [ "mkdir -p ~/.cache/hypr" "mkdir -p ~/Pictures/Screenshots" ]
        # Initialize theme
        [ "echo '${defaultPalette}' > ~/.cache/hypr/current-palette" ]
      ];

      env = [
        "QT_QPA_PLATFORM,wayland;xcb"
        "QT_QPA_PLATFORMTHEME,qt5ct"
        "QT_WAYLAND_DISABLE_WINDOWDECORATION,1"
        "GTK_THEME,Adwaita:dark"
        "GDK_BACKEND,wayland,x11,*"
        "XDG_CURRENT_DESKTOP,Hyprland"
        "XDG_SESSION_TYPE,wayland"
        "CLUTTER_BACKEND,wayland"
        "SDL_VIDEODRIVER,wayland"
        "MOZ_ENABLE_WAYLAND,1"
        "ELECTRON_OZONE_PLATFORM_HINT,auto"
        "XCURSOR_SIZE,24"
      ];

      input = {
        kb_layout = "us";
        kb_options = "caps:escape";
        follow_mouse = 1;
        repeat_delay = 300;
        repeat_rate = 50;
        sensitivity = 0;
        accel_profile = "flat";
        touchpad = lib.mkIf features.hasTouchpad {
          natural_scroll = true;
          tap_to_click = true;
          drag_lock = true;
          disable_while_typing = true;
          clickfinger_behavior = true;
        };
      };

      general = {
        gaps_in = 5;
        gaps_out = 10;
        border_size = 2;
        "col.active_border" = "rgba(${lib.removePrefix "#" p.gradientStart}ee) rgba(${lib.removePrefix "#" p.gradientEnd}ee) ${p.gradientAngle}";
        "col.inactive_border" = "rgba(${lib.removePrefix "#" p.border}aa)";
        layout = "dwindle";
        resize_on_border = true;
        extend_border_grab_area = 15;
        hover_icon_on_border = true;
      };

      decoration = {
        rounding = 12;
        blur = { enabled = true; size = 8; passes = 3; noise = 0.02; vibrancy = 0.2; popups = true; special = true; };
        shadow = { enabled = true; range = 12; render_power = 3; color = "rgba(00000055)"; color_inactive = "rgba(00000033)"; offset = "0 4"; };
        dim_inactive = true;
        dim_strength = 0.08;
        dim_special = 0.3;
      };

      animations = {
        enabled = true;
        first_launch_animation = true;
        bezier = [
          "fluent, 0.05, 0.9, 0.1, 1.05"
          "bounce, 0.68, -0.55, 0.265, 1.55"
          "smooth, 0.25, 0.1, 0.25, 1"
          "snappy, 0.4, 0, 0.2, 1"
        ];
        animation = [
          "windows, 1, 4, fluent, slide"
          "windowsIn, 1, 4, bounce, slide"
          "windowsOut, 1, 3, snappy, slide"
          "windowsMove, 1, 3, smooth"
          "border, 1, 10, default"
          "borderangle, 1, 100, smooth, loop"
          "fade, 1, 4, smooth"
          "fadeDim, 1, 4, smooth"
          "workspaces, 1, 4, fluent, slidevert"
          "specialWorkspace, 1, 4, bounce, slidevert"
          "layers, 1, 3, snappy, fade"
        ];
      };

      dwindle = { pseudotile = true; preserve_split = true; force_split = 2; smart_resizing = true; special_scale_factor = 0.92; };
      master = { new_status = "master"; mfact = 0.55; };

      misc = {
        force_default_wallpaper = 0;
        disable_hyprland_logo = true;
        disable_splash_rendering = true;
        mouse_move_enables_dpms = true;
        key_press_enables_dpms = true;
        vfr = true;
        vrr = 1;
        enable_swallow = true;
        swallow_regex = "^(kitty|foot)$";
        focus_on_activate = true;
        new_window_takes_over_fullscreen = 2;
      };

      gestures = lib.mkIf features.hasTouchpad {
        workspace_swipe = true;
        workspace_swipe_fingers = 3;
        workspace_swipe_distance = 250;
        workspace_swipe_create_new = true;
      };

      binds = { workspace_back_and_forth = true; allow_workspace_cycles = true; };

      "$mod" = "SUPER";
      "$terminal" = "kitty";
      "$menu" = "wofi --show drun -I";
      "$browser" = "brave";

      bind = lib.flatten [
        # Core
        [ "$mod, slash, exec, ~/.config/hypr/scripts/keybind-help.sh" "$mod, F1, exec, ~/.config/hypr/scripts/keybind-help.sh" ]
        [ "$mod, Return, exec, $terminal" "$mod SHIFT, Return, exec, $terminal --class floating-term" ]
        [ "$mod, Space, exec, $menu" "$mod, B, exec, $browser" "$mod, E, exec, thunar" ]
        (lib.optional features.enableDev "$mod, C, exec, code")
        (lib.optional features.enableDev "$mod, O, exec, obsidian")

        # Windows
        [ "$mod, Q, killactive" "$mod SHIFT, Q, exec, hyprctl kill" "$mod, W, togglefloating" ]
        [ "$mod, F, fullscreen, 0" "$mod SHIFT, F, fullscreen, 1" "$mod, P, pseudo" "$mod, X, togglesplit" ]
        [ "$mod, G, togglegroup" "$mod, Tab, changegroupactive, f" "$mod SHIFT, Tab, changegroupactive, b" ]
        [ "$mod SHIFT, C, centerwindow" "$mod SHIFT, P, pin" ]

        # Navigation
        [ "$mod, H, movefocus, l" "$mod, L, movefocus, r" "$mod, K, movefocus, u" "$mod, J, movefocus, d" ]
        [ "$mod, left, movefocus, l" "$mod, right, movefocus, r" "$mod, up, movefocus, u" "$mod, down, movefocus, d" ]
        [ "$mod SHIFT, H, movewindow, l" "$mod SHIFT, L, movewindow, r" "$mod SHIFT, K, movewindow, u" "$mod SHIFT, J, movewindow, d" ]
        [ "$mod, U, focusurgentorlast" ]

        # Workspaces
        [ "$mod, 1, workspace, 1" "$mod, 2, workspace, 2" "$mod, 3, workspace, 3" "$mod, 4, workspace, 4" "$mod, 5, workspace, 5" ]
        [ "$mod, 6, workspace, 6" "$mod, 7, workspace, 7" "$mod, 8, workspace, 8" "$mod, 9, workspace, 9" "$mod, 0, workspace, 10" ]
        [ "$mod SHIFT, 1, movetoworkspace, 1" "$mod SHIFT, 2, movetoworkspace, 2" "$mod SHIFT, 3, movetoworkspace, 3" ]
        [ "$mod SHIFT, 4, movetoworkspace, 4" "$mod SHIFT, 5, movetoworkspace, 5" "$mod SHIFT, 6, movetoworkspace, 6" ]
        [ "$mod SHIFT, 7, movetoworkspace, 7" "$mod SHIFT, 8, movetoworkspace, 8" "$mod SHIFT, 9, movetoworkspace, 9" "$mod SHIFT, 0, movetoworkspace, 10" ]
        [ "$mod, grave, workspace, previous" "$mod, bracketleft, workspace, e-1" "$mod, bracketright, workspace, e+1" ]
        [ "$mod, mouse_down, workspace, e+1" "$mod, mouse_up, workspace, e-1" ]
        [ "$mod, S, togglespecialworkspace, scratchpad" "$mod SHIFT, S, movetoworkspace, special:scratchpad" ]

        # Screenshots
        [ ", Print, exec, ~/.config/hypr/scripts/screenshot.sh screen" "$mod, Print, exec, ~/.config/hypr/scripts/screenshot.sh window" ]
        [ "SHIFT, Print, exec, ~/.config/hypr/scripts/screenshot.sh region" "$mod SHIFT, Print, exec, ~/.config/hypr/scripts/screenshot.sh region-edit" ]
        [ "$mod SHIFT, X, exec, hyprpicker -a -n" ]

        # Clipboard & Session
        [ "$mod, V, exec, cliphist list | wofi --dmenu -p '󰅌 Clipboard' | cliphist decode | wl-copy" ]
        [ "$mod, Escape, exec, wlogout -p layer-shell" "$mod CTRL, L, exec, hyprlock" "$mod SHIFT, Escape, exit" ]

        # Theme switching
        [ "$mod, F8, exec, ~/.config/hypr/scripts/theme-switcher.sh" ]
        [ "$mod SHIFT, F8, exec, ~/.config/hypr/scripts/theme-switcher.sh menu" ]

        # System
        [ "$mod, T, exec, $terminal --title 'Thermal Status' -e bash -c 'thermal-status; read -rp \"Press enter...\"'" ]
        [ "$mod, M, exec, gnome-system-monitor" "$mod, equal, exec, gnome-calculator" ]
        (lib.optional features.enableDCF "$mod, D, exec, $terminal --title 'DCF Control' -e dcf-control")
        (lib.optional features.hasBattery "$mod, F12, exec, ~/.config/hypr/scripts/toggle_clamshell.sh")
      ];

      binde = lib.flatten [
        [ ", XF86AudioRaiseVolume, exec, ~/.config/hypr/scripts/volume.sh up" ]
        [ ", XF86AudioLowerVolume, exec, ~/.config/hypr/scripts/volume.sh down" ]
        (lib.optionals features.hasBacklight [
          ", XF86MonBrightnessUp, exec, ~/.config/hypr/scripts/brightness.sh up"
          ", XF86MonBrightnessDown, exec, ~/.config/hypr/scripts/brightness.sh down"
        ])
        [ "$mod CTRL, H, resizeactive, -40 0" "$mod CTRL, L, resizeactive, 40 0" ]
        [ "$mod CTRL, K, resizeactive, 0 -40" "$mod CTRL, J, resizeactive, 0 40" ]
      ];

      bindl = [
        ", XF86AudioMute, exec, ~/.config/hypr/scripts/volume.sh mute"
        ", XF86AudioMicMute, exec, wpctl set-mute @DEFAULT_AUDIO_SOURCE@ toggle"
        ", XF86AudioPlay, exec, playerctl play-pause"
        ", XF86AudioNext, exec, playerctl next"
        ", XF86AudioPrev, exec, playerctl previous"
      ];

      bindm = [ "$mod, mouse:272, movewindow" "$mod, mouse:273, resizewindow" ];

      windowrulev2 = [
        # Floating
        "float, class:^(pavucontrol|blueman-manager|nm-connection-editor|gnome-calculator|gnome-system-monitor)$"
        "float, class:^(thunar)$, title:^(File Operation|Confirm).*$"
        "float, title:^(Open|Save|Export|Import|Choose|Select|Preferences|Settings|Properties|About).*$"
        "float, class:^(floating-term)$"
        "size 1000 700, class:^(floating-term)$"
        "center, class:^(floating-term)$"
        "animation slide, class:^(floating-term)$"

        # Tool windows
        "float, title:^(Thermal Status|DCF Control|DCF Logs|AI Stack)$"
        "size 650 500, title:^(Thermal Status|DCF Control|DCF Logs|AI Stack)$"
        "center, title:^(Thermal Status|DCF Control|DCF Logs|AI Stack)$"

        # PiP
        "float, title:^(Picture.in.[Pp]icture)$"
        "pin, title:^(Picture.in.[Pp]icture)$"
        "keepaspectratio, title:^(Picture.in.[Pp]icture)$"
        "size 480 270, title:^(Picture.in.[Pp]icture)$"
        "move 100%-490 100%-280, title:^(Picture.in.[Pp]icture)$"
        "nodim, title:^(Picture.in.[Pp]icture)$"

        # Workspace assignments
        "workspace 2, class:^(Code|code-url-handler)$"
        "workspace 3, class:^(obsidian)$"
        "workspace 5, class:^(thunderbird|discord)$"
        "workspace 9 silent, class:^(steam)$"
        "float, class:^(steam)$, title:^(Friends|Settings|Screenshot).*$"

        # Visuals
        "opacity 0.95 0.88, class:^(kitty)$"
        "opacity 0.95 0.90, class:^(Code)$"
        "opacity 1.0 override, fullscreen:1"
        "noborder, fullscreen:1"
        "idleinhibit fullscreen, class:^(brave-browser|firefox|mpv|vlc)$"

        # XWayland bridge
        "opacity 0.0 override, class:^(xwaylandvideobridge)$"
        "noanim, class:^(xwaylandvideobridge)$"
        "noinitialfocus, class:^(xwaylandvideobridge)$"
        "maxsize 1 1, class:^(xwaylandvideobridge)$"
      ];

      layerrule = [
        "blur, waybar"
        "blur, wofi"
        "blur, notifications"
        "blur, logout_dialog"
        "ignorezero, waybar"
        "ignorezero, notifications"
        "animation slide, wofi"
        "animation slide, notifications"
        "animation fade, logout_dialog"
      ];
    };

    extraConfig = lib.mkMerge [
      ''
        workspace = 1, default:true
        workspace = special:scratchpad, gapsout:60, gapsin:20
      ''
      (lib.mkIf features.hasBattery ''
        bindl = , switch:Lid Switch, exec, ~/.config/hypr/scripts/lid.sh close
        bindl = , switch:off:Lid Switch, exec, ~/.config/hypr/scripts/lid.sh open
      '')
    ];
  };

  # ════════════════════════════════════════════════════════════════════════════
  # Waybar - Beautiful Status Bar
  # ════════════════════════════════════════════════════════════════════════════
  programs.waybar = {
    enable = true;
    systemd.enable = false;
    settings.mainBar = {
      layer = "top";
      position = "top";
      height = 42;
      margin-top = 6;
      margin-left = 10;
      margin-right = 10;
      spacing = 0;

      modules-left = mkWaybarModules.left;
      modules-center = mkWaybarModules.center;
      modules-right = mkWaybarModules.right;

      "custom/logo" = {
        format = "󱄅";
        tooltip = "DeMoD Workstation";
        on-click = "wofi --show drun -I";
      };

      "hyprland/workspaces" = {
        format = "{icon}";
        format-icons = {
          "1" = ""; "2" = ""; "3" = "󱓧"; "4" = ""; "5" = "";
          "6" = "󰕧"; "7" = ""; "8" = ""; "9" = "󰓓"; "10" = "";
          urgent = ""; active = ""; default = ""; special = "";
        };
        on-click = "activate";
        on-scroll-up = "hyprctl dispatch workspace e+1";
        on-scroll-down = "hyprctl dispatch workspace e-1";
        persistent-workspaces = { "*" = 5; };
      };

      "hyprland/submap" = { format = " {}"; };

      "hyprland/window" = {
        format = "{title}";
        max-length = 35;
        rewrite = {
          "(.*) — Mozilla Firefox" = " $1";
          "(.*) - Brave" = "󰖟 $1";
          "(.*) - Visual Studio Code" = "󰨞 $1";
          "(.*)kitty" = " Terminal";
          "(.*)thunar(.*)" = "󰉋 Files";
          "" = " Desktop";
        };
      };

      "clock" = {
        interval = 1;
        format = "󰥔  {:%H:%M}";
        format-alt = "󰃭  {:%A, %B %d   󰥔  %H:%M:%S}";
        tooltip-format = "<tt><big>{:%Y %B}</big>\n\n{calendar}</tt>";
        calendar = {
          mode = "month";
          mode-mon-col = 3;
          weeks-pos = "right";
          format = {
            months = "<span color='${p.accent}'><b>{}</b></span>";
            days = "<span color='${p.text}'>{}</span>";
            weeks = "<span color='${p.accentAlt}'><b>W{}</b></span>";
            weekdays = "<span color='${p.warning}'><b>{}</b></span>";
            today = "<span color='${p.bg}' bgcolor='${p.accent}'><b>{}</b></span>";
          };
        };
      };

      "custom/media" = {
        format = "{icon} {}";
        format-icons = { Playing = "󰎆"; Paused = "󰏤"; };
        max-length = 25;
        exec = "playerctl -a metadata --format '{\"text\": \"{{artist}} - {{title}}\", \"alt\": \"{{status}}\"}' -F 2>/dev/null || echo '{}'";
        return-type = "json";
        on-click = "playerctl play-pause";
        on-click-right = "playerctl next";
      };

      "group/audio" = {
        orientation = "horizontal";
        modules = [ "pulseaudio" ] ++ (lib.optional features.hasBacklight "backlight");
      };

      "pulseaudio" = {
        format = "{icon}  {volume}%";
        format-muted = "󰖁  Muted";
        format-icons = { default = [ "󰕿" "󰖀" "󰕾" ]; headphone = "󰋋"; };
        on-click = "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle";
        on-click-right = "pavucontrol";
        on-scroll-up = "wpctl set-volume @DEFAULT_AUDIO_SINK@ 2%+";
        on-scroll-down = "wpctl set-volume @DEFAULT_AUDIO_SINK@ 2%-";
      };

      "backlight" = {
        format = "{icon}  {percent}%";
        format-icons = [ "󰃞" "󰃟" "󰃠" ];
        on-scroll-up = "brightnessctl set 2%+";
        on-scroll-down = "brightnessctl set 2%-";
      };

      "group/network" = {
        orientation = "horizontal";
        modules = [ "network" ] ++ (lib.optional features.hasBluetooth "bluetooth");
      };

      "network" = {
        format-wifi = "󰤨  {signalStrength}%";
        format-ethernet = "󰈀";
        format-disconnected = "󰤭";
        tooltip-format-wifi = "󰤨 {essid}\n󰩟 {ipaddr}\n󰕒 {bandwidthUpBytes}  󰇚 {bandwidthDownBytes}";
        on-click = "nm-connection-editor";
      };

      "bluetooth" = {
        format = "󰂯";
        format-connected = "󰂱 {num_connections}";
        format-disabled = "󰂲";
        on-click = "blueman-manager";
      };

      "group/system" = {
        orientation = "horizontal";
        modules = [ "cpu" "memory" "temperature" ];
      };

      "cpu" = { interval = 5; format = "󰻠 {usage}%"; states = { warning = 70; critical = 90; }; };
      "memory" = { interval = 5; format = "󰍛 {percentage}%"; states = { warning = 70; critical = 90; }; };
      "temperature" = { interval = 5; critical-threshold = 80; format = "{icon} {temperatureC}°"; format-icons = [ "󱃃" "󰔏" "󱃂" ]; };

      "battery" = {
        interval = 30;
        states = { good = 80; warning = 30; critical = 15; };
        format = "{icon}  {capacity}%";
        format-charging = "󰂄  {capacity}%";
        format-plugged = "󰚥  {capacity}%";
        format-icons = [ "󰂎" "󰁺" "󰁻" "󰁼" "󰁽" "󰁾" "󰁿" "󰂀" "󰂁" "󰂂" "󰁹" ];
        tooltip-format = "{timeTo}\n{capacity}% • {health}% health";
      };

      "tray" = { icon-size = 18; spacing = 10; };

      "custom/power" = { format = "󰐥"; tooltip = "Power Menu"; on-click = "wlogout -p layer-shell"; };

      "custom/separator-left" = { format = ""; tooltip = false; };
      "custom/separator-right" = { format = ""; tooltip = false; };
      "custom/separator-dot" = { format = "•"; tooltip = false; };
    };

    style = ''
      /* ═══════════════════════════════════════════════════════════════════════════
       * DeMoD Waybar Theme - Elegant & Modern
       * ═══════════════════════════════════════════════════════════════════════════ */

      * {
        font-family: "JetBrainsMono Nerd Font", "Inter", sans-serif;
        font-size: 13px;
        font-weight: 500;
        min-height: 0;
        border: none;
        border-radius: 0;
        padding: 0;
        margin: 0;
      }

      window#waybar {
        background: linear-gradient(180deg, 
          alpha(${p.bg}, 0.95) 0%, 
          alpha(${p.surface}, 0.90) 100%);
        border-radius: 16px;
        border: 1px solid alpha(${p.border}, 0.6);
        box-shadow: 0 4px 20px rgba(0, 0, 0, 0.4);
      }

      tooltip {
        background: ${p.surface};
        border: 1px solid ${p.accent};
        border-radius: 12px;
        padding: 10px 14px;
      }

      tooltip label {
        color: ${p.text};
      }

      /* ─────────────────────────────────────────────────────────────────────────
       * Logo
       * ───────────────────────────────────────────────────────────────────────── */
      #custom-logo {
        font-size: 20px;
        color: ${p.accent};
        padding: 0 16px 0 14px;
        margin: 6px 4px 6px 6px;
        background: linear-gradient(135deg, 
          alpha(${p.accent}, 0.15) 0%, 
          alpha(${p.accentAlt}, 0.10) 100%);
        border-radius: 12px;
        transition: all 0.3s ease;
      }

      #custom-logo:hover {
        background: linear-gradient(135deg, 
          alpha(${p.accent}, 0.25) 0%, 
          alpha(${p.accentAlt}, 0.20) 100%);
        text-shadow: 0 0 10px ${p.accent};
      }

      /* ─────────────────────────────────────────────────────────────────────────
       * Workspaces
       * ───────────────────────────────────────────────────────────────────────── */
      #workspaces {
        background: alpha(${p.surfaceAlt}, 0.5);
        border-radius: 12px;
        padding: 2px 6px;
        margin: 6px 4px;
      }

      #workspaces button {
        color: ${p.textDim};
        padding: 4px 10px;
        margin: 2px;
        border-radius: 10px;
        background: transparent;
        transition: all 0.3s ease;
      }

      #workspaces button:hover {
        color: ${p.accentAlt};
        background: alpha(${p.accentAlt}, 0.12);
      }

      #workspaces button.active {
        color: ${p.textOnAccent};
        background: linear-gradient(135deg, ${p.gradientStart} 0%, ${p.gradientEnd} 100%);
        box-shadow: 0 2px 8px alpha(${p.accent}, 0.4);
        font-weight: bold;
      }

      #workspaces button.urgent {
        color: ${p.bg};
        background: ${p.error};
        animation: pulse-urgent 1s ease infinite;
      }

      #workspaces button.special {
        color: ${p.purple};
      }

      #workspaces button.special.active {
        background: linear-gradient(135deg, ${p.purple} 0%, ${p.pink} 100%);
        color: ${p.bg};
      }

      @keyframes pulse-urgent {
        0%, 100% { box-shadow: 0 0 8px ${p.error}; }
        50% { box-shadow: 0 0 16px ${p.error}; }
      }

      /* ─────────────────────────────────────────────────────────────────────────
       * Window Title
       * ───────────────────────────────────────────────────────────────────────── */
      #window {
        color: ${p.textAlt};
        padding: 0 12px;
        font-style: italic;
        font-weight: 400;
      }

      /* ─────────────────────────────────────────────────────────────────────────
       * Clock
       * ───────────────────────────────────────────────────────────────────────── */
      #clock {
        color: ${p.accent};
        font-weight: bold;
        font-size: 14px;
        padding: 0 14px;
        margin: 6px;
        background: alpha(${p.surfaceAlt}, 0.6);
        border-radius: 12px;
        transition: all 0.3s ease;
      }

      #clock:hover {
        background: alpha(${p.accent}, 0.15);
        box-shadow: 0 0 12px alpha(${p.accent}, 0.3);
      }

      /* ─────────────────────────────────────────────────────────────────────────
       * Media
       * ───────────────────────────────────────────────────────────────────────── */
      #custom-media {
        color: ${p.accentAlt};
        padding: 0 14px;
        margin: 6px 4px;
        background: alpha(${p.surfaceAlt}, 0.4);
        border-radius: 12px;
      }

      #custom-media.Playing {
        color: ${p.accent};
      }

      #custom-media.Paused {
        color: ${p.textDim};
        font-style: italic;
      }

      /* ─────────────────────────────────────────────────────────────────────────
       * Module Groups
       * ───────────────────────────────────────────────────────────────────────── */
      #audio, #network, #system {
        background: alpha(${p.surfaceAlt}, 0.4);
        border-radius: 12px;
        padding: 0 4px;
        margin: 6px 2px;
      }

      #pulseaudio, #backlight, #network, #bluetooth, #cpu, #memory, #temperature {
        padding: 0 10px;
        color: ${p.text};
        transition: all 0.2s ease;
      }

      #pulseaudio:hover, #backlight:hover, #network:hover, #bluetooth:hover {
        color: ${p.accent};
      }

      #pulseaudio { color: ${p.accentAlt}; }
      #pulseaudio.muted { color: ${p.textDim}; }
      #backlight { color: ${p.warning}; }
      #network { color: ${p.accent}; }
      #network.disconnected { color: ${p.error}; }
      #bluetooth { color: ${p.accentAlt}; }
      #bluetooth.off, #bluetooth.disabled { color: ${p.textDim}; }

      #cpu.warning, #memory.warning { color: ${p.warning}; }
      #cpu.critical, #memory.critical { color: ${p.error}; font-weight: bold; }
      #temperature.critical { color: ${p.error}; animation: pulse-urgent 1s ease infinite; }

      /* ─────────────────────────────────────────────────────────────────────────
       * Battery
       * ───────────────────────────────────────────────────────────────────────── */
      #battery {
        padding: 0 14px;
        margin: 6px 2px;
        background: alpha(${p.surfaceAlt}, 0.4);
        border-radius: 12px;
        color: ${p.accent};
      }

      #battery.warning { color: ${p.warning}; }
      #battery.critical:not(.charging) { 
        color: ${p.error}; 
        animation: pulse-urgent 1s ease infinite;
      }
      #battery.charging, #battery.plugged { color: ${p.accentAlt}; }

      /* ─────────────────────────────────────────────────────────────────────────
       * Tray
       * ───────────────────────────────────────────────────────────────────────── */
      #tray {
        padding: 0 10px;
        margin: 6px 4px;
        background: alpha(${p.surfaceAlt}, 0.3);
        border-radius: 12px;
      }

      #tray > .passive { -gtk-icon-effect: dim; }
      #tray > .needs-attention { -gtk-icon-effect: highlight; }

      /* ─────────────────────────────────────────────────────────────────────────
       * Power Button
       * ───────────────────────────────────────────────────────────────────────── */
      #custom-power {
        color: ${p.error};
        font-size: 18px;
        padding: 0 14px 0 10px;
        margin: 6px 6px 6px 2px;
        background: alpha(${p.error}, 0.1);
        border-radius: 12px;
        transition: all 0.3s ease;
      }

      #custom-power:hover {
        color: ${p.text};
        background: alpha(${p.error}, 0.4);
        box-shadow: 0 0 12px alpha(${p.error}, 0.4);
      }

      /* ─────────────────────────────────────────────────────────────────────────
       * Separators
       * ───────────────────────────────────────────────────────────────────────── */
      #custom-separator-left, #custom-separator-right {
        color: alpha(${p.border}, 0.5);
        font-size: 16px;
        padding: 0 4px;
      }

      #custom-separator-dot {
        color: alpha(${p.accent}, 0.4);
        font-size: 8px;
        padding: 0 8px;
      }

      /* ─────────────────────────────────────────────────────────────────────────
       * Submap
       * ───────────────────────────────────────────────────────────────────────── */
      #submap {
        color: ${p.bg};
        background: linear-gradient(135deg, ${p.warning} 0%, ${p.orange} 100%);
        border-radius: 10px;
        padding: 4px 14px;
        margin: 6px 4px;
        font-weight: bold;
        box-shadow: 0 2px 8px alpha(${p.warning}, 0.4);
      }
    '';
  };

  # ════════════════════════════════════════════════════════════════════════════
  # Kitty Terminal
  # ════════════════════════════════════════════════════════════════════════════
  programs.kitty = {
    enable = true;
    settings = {
      font_family = "JetBrainsMono Nerd Font";
      bold_font = "JetBrainsMono Nerd Font Bold";
      font_size = 11;
      cursor_shape = "beam";
      cursor_blink_interval = 0;
      scrollback_lines = 10000;
      window_padding_width = 12;
      hide_window_decorations = "yes";
      confirm_os_window_close = 0;
      enable_audio_bell = false;
      url_style = "curly";

      background = p.bg;
      foreground = p.text;
      selection_background = p.accent;
      selection_foreground = p.bg;
      cursor = p.accent;
      cursor_text_color = p.bg;

      color0 = p.black;
      color8 = p.brightBlack;
      color1 = p.red;
      color9 = p.brightRed;
      color2 = p.green;
      color10 = p.brightGreen;
      color3 = p.yellow;
      color11 = p.yellow;
      color4 = p.blue;
      color12 = p.brightBlue;
      color5 = p.magenta;
      color13 = p.brightMagenta;
      color6 = p.cyan;
      color14 = p.brightCyan;
      color7 = p.white;
      color15 = p.brightWhite;

      tab_bar_style = "powerline";
      tab_powerline_style = "slanted";
      active_tab_background = p.accent;
      active_tab_foreground = p.bg;
      inactive_tab_background = p.surface;
      inactive_tab_foreground = p.textAlt;
    };
  };

  # ════════════════════════════════════════════════════════════════════════════
  # Mako Notifications
  # ════════════════════════════════════════════════════════════════════════════
  services.mako = {
    enable = true;
    settings = {
      background-color = "rgba(16, 16, 24, 0.95)";
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

      # Urgency levels per Design System
      "urgency=low" = { 
        border-color = "#808080";  # Gray per design system
        default-timeout = 3000; 
      };
      "urgency=normal" = { 
        border-color = p.accent;   # Turquoise per design system
        default-timeout = 5000; 
      };
      "urgency=critical" = { 
        border-color = p.error;    # Coral red per design system
        default-timeout = 0;       # No timeout for critical
      };
      
      # Category-specific settings
      "category=volume" = { default-timeout = 1500; group-by = "category"; };
      "category=brightness" = { default-timeout = 1500; group-by = "category"; };
    };
  };

  # ════════════════════════════════════════════════════════════════════════════
  # Wofi Launcher
  # ════════════════════════════════════════════════════════════════════════════
  home.file.".config/wofi/config".text = ''
    width=650
    height=450
    location=center
    show=drun
    prompt=Search...
    filter_rate=100
    allow_markup=true
    no_actions=true
    insensitive=true
    allow_images=true
    image_size=36
    gtk_dark=true
    layer=overlay
    columns=1
  '';

  home.file.".config/wofi/style.css".text = ''
    /* Wofi Theme - Enhanced UX per Design System */
    * {
      font-family: "JetBrains Mono", "Inter", sans-serif;
      font-size: 14px;
    }

    window {
      background: linear-gradient(180deg, ${p.bg}F8 0%, ${p.surface}F5 100%);
      border: 2px solid ${p.accent};
      border-radius: 20px;
      box-shadow: 0 8px 32px rgba(0, 0, 0, 0.5), 0 0 20px rgba(0, 245, 212, 0.15);
    }

    #input {
      margin: 14px;
      padding: 14px 18px;
      border: 2px solid ${p.border};
      border-radius: 14px;
      background: ${p.bgAlt};
      color: ${p.text};
      font-size: 15px;
      transition: all 0.2s ease;
    }

    #input:focus {
      border-color: ${p.accent};
      box-shadow: 0 0 0 3px alpha(${p.accent}, 0.15);
      background: ${p.surfaceAlt};
    }

    #input::placeholder {
      color: ${p.textDim};
    }

    #inner-box {
      margin: 0 14px 14px 14px;
    }

    #outer-box {
      margin: 0;
    }

    #scroll {
      margin: 0;
    }

    #text {
      color: ${p.text};
    }

    #text:selected {
      color: ${p.textOnAccent};
    }

    #entry {
      padding: 12px 16px;
      margin: 4px 0;
      border-radius: 12px;
      background: transparent;
      transition: all 0.2s ease;
    }

    #entry:selected {
      background: linear-gradient(135deg, ${p.gradientStart} 0%, ${p.gradientEnd} 100%);
      box-shadow: 0 4px 12px alpha(${p.accent}, 0.3);
    }

    #entry:hover {
      background: alpha(${p.accent}, 0.12);
    }

    #entry:selected:hover {
      background: linear-gradient(135deg, ${p.gradientStart} 0%, ${p.gradientEnd} 100%);
    }

    #img {
      margin-right: 12px;
    }

    /* Scrollbar styling */
    scrollbar {
      background: transparent;
    }
    
    scrollbar slider {
      background: alpha(${p.accent}, 0.4);
      border-radius: 4px;
      min-width: 6px;
    }
    
    scrollbar slider:hover {
      background: alpha(${p.accent}, 0.6);
    }
  '';

  # ════════════════════════════════════════════════════════════════════════════
  # Wlogout
  # ════════════════════════════════════════════════════════════════════════════
  home.file.".config/wlogout/layout".text = ''
    {"label":"lock","action":"hyprlock","text":"Lock","keybind":"l"}
    {"label":"logout","action":"hyprctl dispatch exit","text":"Logout","keybind":"e"}
    {"label":"suspend","action":"systemctl suspend","text":"Sleep","keybind":"s"}
    {"label":"reboot","action":"systemctl reboot","text":"Reboot","keybind":"r"}
    {"label":"shutdown","action":"systemctl poweroff","text":"Shutdown","keybind":"p"}
  '';

  home.file.".config/wlogout/style.css".text = ''
    * {
      background-image: none;
      font-family: "JetBrains Mono", sans-serif;
      font-size: 14px;
    }

    window {
      background: linear-gradient(180deg, ${p.bg}E8 0%, ${p.surface}E5 100%);
    }

    button {
      color: ${p.text};
      background: linear-gradient(180deg, ${p.surface} 0%, ${p.surfaceAlt} 100%);
      border: 2px solid ${p.border};
      border-radius: 20px;
      margin: 12px;
      padding: 20px;
      background-repeat: no-repeat;
      background-position: center 30%;
      background-size: 30%;
      box-shadow: 0 4px 16px rgba(0, 0, 0, 0.3);
      transition: all 0.3s ease;
    }

    button:focus, button:hover {
      background: linear-gradient(135deg, ${p.gradientStart} 0%, ${p.gradientEnd} 100%);
      color: ${p.textOnAccent};
      border-color: ${p.accent};
      box-shadow: 0 6px 24px alpha(${p.accent}, 0.4);
      transform: scale(1.02);
    }

    #lock:focus, #lock:hover { background: linear-gradient(135deg, ${p.info} 0%, ${p.accent} 100%); }
    #logout:focus, #logout:hover { background: linear-gradient(135deg, ${p.warning} 0%, ${p.orange} 100%); }
    #suspend:focus, #suspend:hover { background: linear-gradient(135deg, ${p.purple} 0%, ${p.pink} 100%); }
    #reboot:focus, #reboot:hover { background: linear-gradient(135deg, ${p.accentAlt} 0%, ${p.info} 100%); }
    #shutdown:focus, #shutdown:hover { background: linear-gradient(135deg, ${p.error} 0%, ${p.pink} 100%); }
  '';

  # ════════════════════════════════════════════════════════════════════════════
  # Hyprlock
  # ════════════════════════════════════════════════════════════════════════════
  home.file.".config/hypr/hyprlock.conf".text = ''
    general {
      disable_loading_bar = false
      hide_cursor = true
      grace = 3
    }

    background {
      monitor =
      path = screenshot
      blur_passes = 4
      blur_size = 10
      brightness = 0.6
      vibrancy = 0.2
    }

    # Time
    label {
      monitor =
      text = $TIME
      font_size = 96
      font_family = JetBrains Mono Bold
      color = rgba(${lib.removePrefix "#" p.accent}ff)
      position = 0, 180
      halign = center
      valign = center
      shadow_passes = 2
      shadow_size = 4
      shadow_color = rgba(0, 0, 0, 0.5)
    }

    # Date
    label {
      monitor =
      text = cmd[update:3600000] date +"%A, %B %d"
      font_size = 20
      font_family = JetBrains Mono
      color = rgba(${lib.removePrefix "#" p.textAlt}dd)
      position = 0, 80
      halign = center
      valign = center
    }

    # User
    label {
      monitor =
      text = 󰀄  $USER
      font_size = 16
      font_family = JetBrainsMono Nerd Font
      color = rgba(${lib.removePrefix "#" p.text}cc)
      position = 0, -60
      halign = center
      valign = center
    }

    # Input
    input-field {
      monitor =
      size = 320, 55
      outline_thickness = 3
      dots_size = 0.25
      dots_spacing = 0.2
      dots_center = true
      outer_color = rgba(${lib.removePrefix "#" p.accent}ee)
      inner_color = rgba(${lib.removePrefix "#" p.surface}ee)
      font_color = rgba(${lib.removePrefix "#" p.text}ff)
      fade_on_empty = false
      placeholder_text = <i>󰌾  Enter Password...</i>
      hide_input = false
      position = 0, -140
      halign = center
      valign = center
      rounding = 14
      shadow_passes = 2
      shadow_size = 4
    }

    # Brand
    label {
      monitor =
      text = 󱄅  DeMoD Workstation
      font_size = 12
      font_family = JetBrainsMono Nerd Font
      color = rgba(${lib.removePrefix "#" p.textDim}88)
      position = 0, -240
      halign = center
      valign = center
    }
  '';

  # ════════════════════════════════════════════════════════════════════════════
  # Scripts
  # ════════════════════════════════════════════════════════════════════════════

  # Theme Switcher
  home.file.".config/hypr/scripts/theme-switcher.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      CACHE="''${XDG_CACHE_HOME:-$HOME/.cache}/hypr/current-palette"
      mkdir -p "$(dirname "$CACHE")"
      
      # Theme definitions: id|name|gradient_start|gradient_end|angle
      themes=(
        "demod|󱄅 DeMoD|00F5D4|8B5CF6|135deg"
        "catppuccin| Catppuccin|CBA6F7|F5C2E7|45deg"
        "nord| Nord|88C0D0|81A1C1|45deg"
        "rosepine|󰧱 Rosé Pine|C4A7E7|EBBCBA|45deg"
        "dracula| Dracula|BD93F9|FF79C6|45deg"
        "gruvbox| Gruvbox|D79921|FABD2F|45deg"
        "tokyo| Tokyo Night|7AA2F7|BB9AF7|45deg"
        "phosphor|󰍹 Phosphor|39FF14|00FF88|180deg"
      )
      
      current=$(cat "$CACHE" 2>/dev/null || echo "demod")
      
      if [[ "''${1:-}" == "menu" ]]; then
        # Build menu with colored icons
        menu=""
        for theme in "''${themes[@]}"; do
          IFS='|' read -r id name start end angle <<< "$theme"
          [[ "$id" == "$current" ]] && marker=" ✓" || marker=""
          menu+="$name$marker\n"
        done
        
        selected=$(echo -e "$menu" | wofi --dmenu -p "󰏘 Theme" --cache-file /dev/null --width 280 --height 400)
        [[ -z "$selected" ]] && exit 0
        
        # Remove marker and find matching theme
        selected=$(echo "$selected" | sed 's/ ✓$//')
        for theme in "''${themes[@]}"; do
          IFS='|' read -r id name start end angle <<< "$theme"
          [[ "$name" == "$selected" ]] && { current="$id"; break; }
        done
      else
        # Cycle to next theme
        theme_ids=()
        for theme in "''${themes[@]}"; do
          IFS='|' read -r id rest <<< "$theme"
          theme_ids+=("$id")
        done
        
        for i in "''${!theme_ids[@]}"; do
          if [[ "''${theme_ids[$i]}" == "$current" ]]; then
            current="''${theme_ids[$(( (i + 1) % ''${#theme_ids[@]} ))]}"
            break
          fi
        done
      fi
      
      echo "$current" > "$CACHE"
      
      # Find and apply the selected theme
      for theme in "''${themes[@]}"; do
        IFS='|' read -r id name start end angle <<< "$theme"
        if [[ "$id" == "$current" ]]; then
          hyprctl keyword general:col.active_border "rgba(''${start}ee) rgba(''${end}ee) $angle"
          
          # Update inactive border based on theme
          case "$id" in
            demod|phosphor) hyprctl keyword general:col.inactive_border "rgba(252530aa)" ;;
            *)              hyprctl keyword general:col.inactive_border "rgba(404050aa)" ;;
          esac
          
          notify-send -t 2500 -h string:x-canonical-private-synchronous:theme \
            -i preferences-desktop-theme \
            "󰏘 Theme Switched" "$name\n<span color='#$start'>━━━━</span><span color='#$end'>━━━━</span>"
          break
        fi
      done
      
      # Hint about full theme switch
      if [[ "''${1:-}" == "menu" ]]; then
        notify-send -t 4000 "󰋼 Note" "Border colors updated.\nRebuild config for full theme."
      fi
    '';
  };

  # Volume
  home.file.".config/hypr/scripts/volume.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      step="''${2:-5}"
      
      get_icon() {
        vol=$1; mute=$2
        [[ "$mute" == "yes" ]] && echo "󰖁" && return
        [[ $vol -ge 70 ]] && echo "󰕾" || [[ $vol -ge 30 ]] && echo "󰖀" || echo "󰕿"
      }
      
      send_notif() {
        vol=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ | awk '{print int($2*100)}')
        mute=$(wpctl get-volume @DEFAULT_AUDIO_SINK@ | grep -q MUTED && echo "yes" || echo "no")
        icon=$(get_icon "$vol" "$mute")
        text=$([[ $mute == "yes" ]] && echo "Muted" || echo "$vol%")
        
        notify-send -t 1500 -h string:x-canonical-private-synchronous:volume \
          -h int:value:"$vol" "$icon  Volume" "$text"
      }
      
      case "''${1:-}" in
        up)   wpctl set-volume -l 1.0 @DEFAULT_AUDIO_SINK@ "$step%+"; send_notif ;;
        down) wpctl set-volume @DEFAULT_AUDIO_SINK@ "$step%-"; send_notif ;;
        mute) wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle; send_notif ;;
      esac
    '';
  };

  # Brightness
  home.file.".config/hypr/scripts/brightness.sh" = lib.mkIf features.hasBacklight {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      step="''${2:-5}"
      
      send_notif() {
        brightness=$(brightnessctl -m | cut -d',' -f4 | tr -d '%')
        [[ $brightness -ge 70 ]] && icon="󰃠" || [[ $brightness -ge 30 ]] && icon="󰃟" || icon="󰃞"
        
        notify-send -t 1500 -h string:x-canonical-private-synchronous:brightness \
          -h int:value:"$brightness" "$icon  Brightness" "$brightness%"
      }
      
      case "''${1:-}" in
        up)   brightnessctl set "$step%+"; send_notif ;;
        down) brightnessctl set "$step%-"; send_notif ;;
      esac
    '';
  };

  # Screenshot
  home.file.".config/hypr/scripts/screenshot.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      set -euo pipefail
      DIR="$HOME/Pictures/Screenshots"
      mkdir -p "$DIR"
      FILE="$DIR/$(date +'%Y-%m-%d_%H%M%S').png"
      
      notify() { notify-send -t 3000 -i camera-photo "󰄀  Screenshot" "$1"; }
      
      case "''${1:-region}" in
        screen)      grim "$FILE" && wl-copy < "$FILE" && notify "Screen saved" ;;
        window)      grim -g "$(hyprctl activewindow -j | jq -r '"\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])"')" "$FILE" && wl-copy < "$FILE" && notify "Window saved" ;;
        region)      grim -g "$(slurp -d)" "$FILE" && wl-copy < "$FILE" && notify "Region saved" ;;
        region-edit) grim -g "$(slurp -d)" - | swappy -f - ;;
      esac
    '';
  };

  # Keybind Help
  home.file.".config/hypr/scripts/keybind-help.sh" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      # DeMoD palette - white on black with turquoise/violet accents
      CYAN="#00F5D4"      # Electric turquoise
      VIOLET="#8B5CF6"    # Electric violet  
      YELLOW="#FFE814"    # Banana yellow
      GREEN="#39FF14"     # Electric green
      WHITE="#FFFFFF"     # Pure white
      
      echo "
      <b><span color='$CYAN'>══════ CORE ══════</span></b>
      <span color='$GREEN'>Super + /</span>          Help
      <span color='$GREEN'>Super + Space</span>      Launcher
      <span color='$GREEN'>Super + Return</span>     Terminal
      <span color='$GREEN'>Super + B</span>          Browser
      <span color='$GREEN'>Super + E</span>          Files

      <b><span color='$CYAN'>══════ WINDOWS ══════</span></b>
      <span color='$GREEN'>Super + Q</span>          Close
      <span color='$GREEN'>Super + W</span>          Float
      <span color='$GREEN'>Super + F</span>          Fullscreen
      <span color='$GREEN'>Super + H/J/K/L</span>    Focus (vim)
      <span color='$GREEN'>Super+Shift + ↑</span>    Move Window
      <span color='$GREEN'>Super+Ctrl + ↑</span>     Resize

      <b><span color='$CYAN'>══════ WORKSPACES ══════</span></b>
      <span color='$GREEN'>Super + 1-0</span>        Switch WS
      <span color='$GREEN'>Super+Shift + 1-0</span>  Move to WS
      <span color='$GREEN'>Super + \`</span>          Previous
      <span color='$GREEN'>Super + [ / ]</span>      Prev/Next
      <span color='$GREEN'>Super + S</span>          Scratchpad

      <b><span color='$VIOLET'>══════ THEME ══════</span></b>
      <span color='$YELLOW'>Super + F8</span>         Cycle Theme
      <span color='$YELLOW'>Super+Shift + F8</span>   Theme Menu

      <b><span color='$CYAN'>══════ MEDIA ══════</span></b>
      <span color='$GREEN'>Print</span>              Screenshot
      <span color='$GREEN'>Super + Print</span>      Window Shot
      <span color='$GREEN'>Shift + Print</span>      Region Shot
      <span color='$GREEN'>Super + V</span>          Clipboard

      <b><span color='$VIOLET'>══════ SYSTEM ══════</span></b>
      <span color='$YELLOW'>Super + Escape</span>     Power Menu
      <span color='$YELLOW'>Super + Ctrl + L</span>   Lock
      <span color='$GREEN'>Super + T</span>          Thermals
      <span color='$GREEN'>Super + M</span>          Monitor
      " | wofi --dmenu -p "󰌌 Keybinds" --cache-file /dev/null --width 420 --height 650 --allow-markup
    '';
  };

  # Thermal Status
  home.file.".local/bin/thermal-status" = {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      # DeMoD Colors - white on black
      CYAN=$'\033[38;2;0;245;212m'      # Electric turquoise
      VIOLET=$'\033[38;2;139;92;246m'   # Electric violet
      GREEN=$'\033[38;2;57;255;20m'     # Electric green
      YELLOW=$'\033[38;2;255;232;20m'   # Banana yellow
      RED=$'\033[38;2;255;59;92m'       # Coral red
      WHITE=$'\033[38;2;255;255;255m'   # Pure white
      DIM=$'\033[38;2;128;128;128m'     # Neutral gray
      RESET=$'\033[0m'
      
      echo ""
      echo "''${CYAN}  ╔══════════════════════════════════════╗''${RESET}"
      echo "''${CYAN}  ║''${RESET}  ''${VIOLET}󱃂''${RESET}  ''${WHITE}THERMAL STATUS''${RESET}                  ''${CYAN}║''${RESET}"
      echo "''${CYAN}  ╚══════════════════════════════════════╝''${RESET}"
      echo ""
      
      echo "  ''${CYAN}┌─ TEMPERATURES ─────────────────────┐''${RESET}"
      if command -v sensors &>/dev/null; then
        sensors 2>/dev/null | grep -E "(Tctl|Tdie|Core|edge|junction)" | head -8 | while read line; do
          # Color code based on temperature
          temp=$(echo "$line" | grep -oP '\+\d+' | head -1 | tr -d '+')
          if [[ -n "$temp" ]]; then
            if [[ $temp -ge 80 ]]; then
              echo "  ''${RED}󰈸''${RESET}  ''${WHITE}$line''${RESET}"
            elif [[ $temp -ge 60 ]]; then
              echo "  ''${YELLOW}󰔏''${RESET}  ''${WHITE}$line''${RESET}"
            else
              echo "  ''${GREEN}󱃃''${RESET}  ''${WHITE}$line''${RESET}"
            fi
          else
            echo "  ''${CYAN}󰔏''${RESET}  ''${WHITE}$line''${RESET}"
          fi
        done
      else
        echo "  ''${DIM}  sensors not found''${RESET}"
      fi
      echo "  ''${CYAN}└────────────────────────────────────┘''${RESET}"
      
      echo ""
      echo "  ''${CYAN}┌─ FANS ─────────────────────────────┐''${RESET}"
      fan_found=false
      for hwmon in /sys/class/hwmon/hwmon*; do
        for fan in "$hwmon"/fan*_input; do
          [[ -f "$fan" ]] || continue
          fan_found=true
          rpm=$(cat "$fan" 2>/dev/null || echo 0)
          name=$(cat "$hwmon/name" 2>/dev/null || echo "Fan")
          if [[ $rpm -gt 0 ]]; then
            echo "  ''${GREEN}󰈐''${RESET}  ''${WHITE}$name:''${RESET} ''${GREEN}$rpm RPM''${RESET}"
          else
            echo "  ''${DIM}󰈐  $name: OFF''${RESET}"
          fi
        done
      done
      [[ "$fan_found" == "false" ]] && echo "  ''${DIM}  No fans detected''${RESET}"
      echo "  ''${CYAN}└────────────────────────────────────┘''${RESET}"
      
      echo ""
      echo "  ''${CYAN}┌─ POWER ────────────────────────────┐''${RESET}"
      if [[ -f /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor ]]; then
        gov=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null)
        echo "  ''${YELLOW}󰓅''${RESET}  ''${WHITE}CPU Governor:''${RESET} ''${GREEN}$gov''${RESET}"
      fi
      if [[ -f /sys/class/drm/card0/device/power_dpm_force_performance_level ]]; then
        level=$(cat /sys/class/drm/card0/device/power_dpm_force_performance_level 2>/dev/null)
        echo "  ''${YELLOW}󰾆''${RESET}  ''${WHITE}GPU Power:''${RESET} ''${GREEN}$level''${RESET}"
      fi
      echo "  ''${CYAN}└────────────────────────────────────┘''${RESET}"
      echo ""
    '';
  };

  # Lid Script
  home.file.".config/hypr/scripts/lid.sh" = lib.mkIf features.hasBattery {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      case "''${1:-}" in
        close) hyprctl monitors -j | jq -e 'length > 1' >/dev/null 2>&1 && hyprctl keyword monitor "eDP-1,disable" ;;
        open)  hyprctl keyword monitor "eDP-1,preferred,auto,1" ;;
      esac
    '';
  };

  home.file.".config/hypr/scripts/toggle_clamshell.sh" = lib.mkIf features.hasBattery {
    executable = true;
    text = ''
      #!/usr/bin/env bash
      if ! hyprctl monitors -j | jq -e '.[] | select(.name | test("^(DP|HDMI)"))' >/dev/null 2>&1; then
        notify-send -i dialog-warning "Clamshell" "No external monitor"
        exit 1
      fi
      if hyprctl monitors -j | jq -e '.[] | select(.name | test("^eDP"))' >/dev/null 2>&1; then
        hyprctl keyword monitor "eDP-1,disable"
        notify-send "󰍹 Clamshell" "Laptop screen disabled"
      else
        hyprctl keyword monitor "eDP-1,preferred,auto,1"
        notify-send "󰍹 Clamshell" "Laptop screen enabled"
      fi
    '';
  };

  # Hypridle
  home.file.".config/hypr/hypridle.conf".text = ''
    general {
      lock_cmd = pidof hyprlock || hyprlock
      before_sleep_cmd = loginctl lock-session
      after_sleep_cmd = hyprctl dispatch dpms on
    }
    listener { timeout = 240; on-timeout = brightnessctl -s set 10%; on-resume = brightnessctl -r; }
    listener { timeout = 300; on-timeout = loginctl lock-session; }
    listener { timeout = 360; on-timeout = hyprctl dispatch dpms off; on-resume = hyprctl dispatch dpms on; }
    listener { timeout = 600; on-timeout = systemctl suspend; }
  '';

  # Hyprpaper
  home.file.".config/hypr/hyprpaper.conf".text = ''
    preload = ~/.config/hypr/wallpapers/default.png
    wallpaper = ,~/.config/hypr/wallpapers/default.png
    splash = false
    ipc = on
  '';

  # Git
  programs.git = {
    enable = true;
    userName = "Asher";
    extraConfig = {
      init.defaultBranch = "main";
      pull.rebase = true;
      push.autoSetupRemote = true;
      core.editor = "nvim";
    };
  };

  programs.lazygit.enable = features.enableDev;
  programs.gh = lib.mkIf features.enableDev { enable = true; settings.git_protocol = "ssh"; };

  # Bash
  programs.bash = {
    enable = true;
    shellAliases = {
      ll = "eza -la --icons --git";
      ls = "eza --icons";
      la = "eza -a --icons";
      lt = "eza --tree --icons --level=2";
      cat = "bat";
      grep = "rg";
      ".." = "cd ..";
      "..." = "cd ../..";
      rebuild = "sudo nixos-rebuild switch --flake .";
      rebuild-test = "sudo nixos-rebuild test --flake .";
      nix-clean = "sudo nix-collect-garbage -d";
      dps = "docker ps --format 'table {{.Names}}\t{{.Status}}'";
      dpa = "docker ps -a --format 'table {{.Names}}\t{{.Status}}'";
      ports = "ss -tulanp";
      myip = "curl -s ifconfig.me";
    };
    initExtra = ''
      # ══════════════════════════════════════════════════════════════════════════
      # DeMoD Terminal Configuration - White on Black
      # ══════════════════════════════════════════════════════════════════════════
      
      # Colors - turquoise/violet accents, white text
      CYAN=$'\033[38;2;0;245;212m'
      VIOLET=$'\033[38;2;139;92;246m'
      GREEN=$'\033[38;2;57;255;20m'
      YELLOW=$'\033[38;2;255;232;20m'
      WHITE=$'\033[38;2;255;255;255m'
      DIM=$'\033[38;2;128;128;128m'
      RESET=$'\033[0m'
      
      # Clean prompt with turquoise/violet accent
      # ╭─[user@host] ~/path
      # ╰─▶ 
      PS1="\[''${CYAN}\]╭─\[''${VIOLET}\][\[''${WHITE}\]\u\[''${CYAN}\]@\[''${WHITE}\]\h\[''${VIOLET}\]]\[''${RESET}\] \[''${GREEN}\]\w\[''${RESET}\]\n\[''${CYAN}\]╰─\[''${VIOLET}\]▶\[''${RESET}\] "
      
      # History configuration
      HISTSIZE=50000
      HISTFILESIZE=100000
      HISTCONTROL=ignoreboth:erasedups
      shopt -s histappend
      
      # Shell options
      shopt -s cdspell autocd dirspell checkwinsize
      
      # FZF integration
      command -v fzf &>/dev/null && eval "$(fzf --bash)"
      
      # Welcome message (only for interactive shells)
      if [[ $- == *i* ]] && [[ -z "$DEMOD_WELCOMED" ]]; then
        export DEMOD_WELCOMED=1
        echo ""
        echo -e "''${CYAN}  ╔══════════════════════════════════════════╗''${RESET}"
        echo -e "''${CYAN}  ║''${RESET}  ''${VIOLET}󱄅''${RESET}  ''${WHITE}DeMoD Workstation''${RESET}                   ''${CYAN}║''${RESET}"
        echo -e "''${CYAN}  ║''${RESET}  ''${DIM}Turquoise • Violet • Abstract''${RESET}          ''${CYAN}║''${RESET}"
        echo -e "''${CYAN}  ╚══════════════════════════════════════════╝''${RESET}"
        echo ""
      fi
    '';
  };

  home.sessionVariables = {
    EDITOR = "nvim";
    BROWSER = "brave";
    TERMINAL = "kitty";
    # Qt theming
    QT_QPA_PLATFORMTHEME = "qt5ct";
    QT_STYLE_OVERRIDE = "kvantum";
  };
  home.sessionPath = [ "$HOME/.local/bin" ];

  # Placeholders
  home.file."Pictures/Screenshots/.keep".text = "";
  home.file.".config/hypr/wallpapers/.keep".text = "";
  home.file.".local/bin/.keep".text = "";
}

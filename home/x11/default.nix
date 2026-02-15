{ config, pkgs, lib, theme ? {}, features ? {}, ... }:

let
  p = theme;
  
  # Session definitions
  sessions = {
    # Wayland Sessions
    hyprland = {
      name = "Hyprland";
      type = "wayland";
      exec = "Hyprland";
      comment = "Hyprland Wayland Compositor";
    };
    plasma = {
      name = "Plasma";
      type = "wayland";
      exec = "plasmashell";
      comment = "KDE Plasma Wayland Session";
    };
    
    # X11 Sessions
    plasma-x11 = {
      name = "Plasma (X11)";
      type = "x11";
      exec = "startplasma-x11";
      comment = "KDE Plasma X11 Session";
    };
    icewm = {
      name = "IceWM";
      type = "x11";
      exec = "icewm-session";
      comment = "IceWM Window Manager";
    };
    leftwm = {
      name = "LeftWM";
      type = "x11";
      exec = "leftwm";
      comment = "LeftWM Tiling Window Manager";
    };
    dwm = {
      name = "DWM";
      type = "x11";
      exec = "dwm";
      comment = "DWM Dynamic Window Manager";
    };
  };
  
  # Active session based on feature flag
  activeSession = features.sessionType or "wayland";
  activeWM = features.x11Wm or "icewm";
  
in {
  # ════════════════════════════════════════════════════════════════════════════
  # X11 Base Configuration
  # ════════════════════════════════════════════════════════════════════════════
  
  imports = [
    ./icewm.nix
    ./leftwm.nix
  ];

  # ════════════════════════════════════════════════════════════════════════════
  # X11 Environment Variables
  # ════════════════════════════════════════════════════════════════════════════
  home.sessionVariables = lib.mkIf (activeSession == "x11") {
    # X11 Specific
    XDG_CURRENT_DESKTOP = "X11";
    XDG_SESSION_TYPE = "x11";
    XDG_SESSION_DESKTOP = activeWM;
    
    # Qt for X11
    QT_QPA_PLATFORM = "xcb";
    QT_QPA_PLATFORMTHEME = "qt5ct";
    QT_STYLE_OVERRIDE = "kvantum";
    QT_AUTO_SCREEN_SCALE_FACTOR = "1";
    
    # GTK
    GTK_THEME = "Adwaita:dark";
    GDK_BACKEND = "x11";
    
    # Cursor
    XCURSOR_THEME = "idTech4";
    XCURSOR_SIZE = "24";
    
    # Disable Wayland-specific features
    SDL_VIDEODRIVER = "x11";
    CLUTTER_BACKEND = "x11";
    MOZ_ENABLE_WAYLAND = "0";
    ELECTRON_OZONE_PLATFORM_HINT = "x11";
  };

  # ════════════════════════════════════════════════════════════════════════════
  # Dunst Notifications (X11 alternative to mako)
  # ════════════════════════════════════════════════════════════════════════════
  services.dunst = lib.mkIf (activeSession == "x11") {
    enable = true;
    settings = {
      global = {
        width = 380;
        height = 300;
        offset = "12x12";
        origin = "top-right";
        frame_width = 2;
        frame_color = p.accent;
        font = "JetBrains Mono 11";
        corner_radius = 14;
        transparency = 10;
      };
      urgency_low = {
        background = p.surface;
        foreground = p.textDim;
        frame_color = p.textDim;
      };
      urgency_normal = {
        background = p.surface;
        foreground = p.text;
        frame_color = p.accent;
      };
      urgency_critical = {
        background = p.surface;
        foreground = p.error;
        frame_color = p.error;
        timeout = 0;
      };
    };
  };

  # ════════════════════════════════════════════════════════════════════════════
  # X11 Utilities
  # ════════════════════════════════════════════════════════════════════════════
  home.file.".Xresources" = {
    text = ''
! ═══════════════════════════════════════════════════════════════════════════
! X11 Resources - DeMoD Theme
! ═══════════════════════════════════════════════════════════════════════════

! Colors
*background: ${p.bg}
*foreground: ${p.text}

! Text
*.color0:  ${p.black}
*.color1:  ${p.red}
*.color2:  ${p.green}
*.color3:  ${p.yellow}
*.color4:  ${p.blue}
*.color5:  ${p.magenta}
*.color6:  ${p.cyan}
*.color7:  ${p.white}
*.color8:  ${p.brightBlack}
*.color9:  ${p.brightRed}
*.color10: ${p.brightGreen}
*.color11: ${p.brightYellow}
*.color12: ${p.brightBlue}
*.color13: ${p.brightMagenta}
*.color14: ${p.brightCyan}
*.color15: ${p.brightWhite}

! URxvt
URxvt*font: xft:JetBrains Mono:size=11
URxvt*boldFont: xft:JetBrains Mono:size=11
URxvt*italicFont: xft:JetBrains Mono:size=11
URxvt*boldItalicFont: xft:JetBrains Mono:size=11
URxvt*letterSpace: 0
URxvt*lineSpace: 0
URxvt*internalBorder: 8
URxvt*externalBorder: 0
URxvt*scrollBar: false
URxvt*termName: rxvt
URxvt*cursorBlink: true
URxvt*cursorUnderline: false
URxvt*visualBell: false
URxvt*saveLines: 10000
URxvt*mapAlert: true
URxvt*metaSendsEscape: true
URxvt*altSendsEscape: true
URxvt*iso14755: false

! XTerm
XTerm*font: JetBrains Mono:size=11
XTerm*boldFont: JetBrains Mono:size=11
XTerm*italicFont: JetBrains Mono:size=11
XTerm*boldItalicFont: JetBrains Mono:size=11
XTerm*cursorBlink: true
XTerm*termName: xterm-color

! XClock
XClock*update: 1
XClock*analog: false
XClock*strftime: " %H:%M:%S "
XClock*fg: ${p.text}
XClock*bg: ${p.surface}
XClock*Padding: 4px

! XLoad
XLoad*foreground: ${p.text}
XLoad*background: ${p.surface}
XLoad*highlight: ${p.accent}

! Xpdf
Xpdf*foreground: ${p.text}
Xpdf*background: ${p.bg}
Xpdf*font: JetBrains Mono
    '';
  };

  # ════════════════════════════════════════════════════════════════════════════
  # X11 Cursor (already configured globally, ensure for X11)
  # ════════════════════════════════════════════════════════════════════════════
  home.pointerCursor = {
    gtk.enable = lib.mkIf (activeSession == "x11") true;
    x11.enable = lib.mkIf (activeSession == "x11") true;
    package = pkgs.bibata-cursors;
    name = "idTech4";
    size = 24;
  };

  # ════════════════════════════════════════════════════════════════════════════
  # X11 Composite Manager (optional - for transparency)
  # ════════════════════════════════════════════════════════════════════════════
  home.file.".config/picom.conf" = lib.mkIf (activeSession == "x11") {
    text = ''
# ═══════════════════════════════════════════════════════════════════════════
# Picom Composite Manager - X11
# ═══════════════════════════════════════════════════════════════════════════

# Backend
backend = "xrender";

# General
vsync = true;
dithered = true;
refresh-rate = 0;
enable-glx = false;
use-damage = true;

# Fading
fading = true;
fade-in-step = 0.03;
fade-out-step = 0.03;
fade-delta = 5;

# Blur
blur-background = true;
blur-method = "gaussian";
blur-size = 8;
blur-deviation = 3;
blur-strength = 5;

# Shadows
shadow = true;
shadow-radius = 12;
shadow-offset-x = 0;
shadow-offset-y = 4;
shadow-opacity = 0.4;
shadow-exclude = [ "class_g = 'Conky'" ];

# Transparency
inactive-opacity = 0.9;
active-opacity = 1.0;
frame-opacity = 0.9;

# Exclusions
exclude = [
  "class_g = 'Polybar'",
  "class_g = 'Tint2'",
  "class_g = 'Docks'",
  "class_g = 'xfce4-panel'",
  "name = 'Notification'",
  "window_type = 'dock'",
  "window_type = 'desktop'"
];

# Animations (experimental)
animations = true;
animation-stiffness = 80;
animation-dampening = 15;
animation-clamping = true;
animation-forall-switch = false;
    '';
  };

  # ════════════════════════════════════════════════════════════════════════════
  # GTK Theme for X11
  # ════════════════════════════════════════════════════════════════════════════
  gtk = {
    enable = lib.mkIf (activeSession == "x11") true;
    theme = {
      package = pkgs.adwaita-theme;
      name = "Adwaita-dark";
    };
    iconTheme = {
      package = pkgs.papirus-icon-theme;
      name = "Papirus-Dark";
    };
    gtk3.extraConfig = lib.mkIf (activeSession == "x11") ''
      [Settings]
      gtk-application-prefer-dark-theme=1
      gtk-cursor-theme-name=idTech4
      gtk-cursor-theme-size=24
      gtk-font-name=JetBrains Mono 11
      gtk-icon-theme-name=Papirus-Dark
      gtk-theme-name=Adwaita-dark
    '';
    gtk4.extraConfig = lib.mkIf (activeSession == "x11") ''
      [Settings]
      gtk-application-prefer-dark-theme=1
    '';
  };

  # ════════════════════════════════════════════════════════════════════════════
  # Qt Theming for X11
  # ════════════════════════════════════════════════════════════════════════════
  qt = {
    enable = lib.mkIf (activeSession == "x11") true;
    platformTheme.name = "qt5ct";
    style.name = "kvantum-dark";
  };
}

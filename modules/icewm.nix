{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.custom.icewm;
in {
  options.custom.icewm = {
    enable = mkEnableOption "IceWM window manager configuration";
    
    theme = mkOption {
      type = types.str;
      default = "default";
      description = "IceWM theme to use";
    };
  };

  config = mkIf cfg.enable {
    environment.etc."icewm/preferences".text = ''
      # IceWM Configuration for Backup System
      # Optimized for minimal resource usage and stability
      
      # Focus and Behavior
      ClickToFocus=1
      FocusOnAppRaise=1
      RequestFocusOnAppRaise=1
      RaiseOnFocus=0
      RaiseOnClickClient=1
      PassFirstClickToClient=1
      
      # Task Bar
      ShowTaskBar=1
      TaskBarAtTop=0
      TaskBarKeepBelow=0
      TaskBarAutoHide=0
      TaskBarShowClock=1
      TaskBarShowAPMStatus=0
      TaskBarShowCPUStatus=1
      TaskBarShowMemStatus=1
      TaskBarShowNetStatus=1
      
      # Menu
      MenuMouseTracking=1
      ShowProgramsMenu=1
      ShowSettingsMenu=1
      ShowHelpMenu=1
      ShowRunMenu=1
      ShowLogoutMenu=1
      ShowLogoutSubMenu=1
      
      # Window Behavior
      SmartWindowPlacement=1
      AutoWindowArrange=1
      HideTitleBarWhenMaximized=0
      MenuMaximizedWidth=640
      Opacity=100
      
      # Performance
      GrabServerToAvoidRace=1
      DelayedFocusChange=1
      DelayedWindowMove=1
      
      # Workspaces
      WorkspaceNames=" 1 ", " 2 ", " 3 ", " 4 "
      LimitToWorkarea=1
      
      # Keys (minimal setup - let users customize)
      # Alt+Tab for window switching is built-in
      # Win+Menu for application menu is built-in
      
      # Theme Integration
      ThemeName="${cfg.theme}/theme.theme"
      
      # Fonts
      TitleBarFontName="-*-sans-medium-r-*-*-12-*-*-*-*-*-*-*"
      MenuFontName="-*-sans-medium-r-*-*-12-*-*-*-*-*-*-*"
      StatusFontName="-*-sans-medium-r-*-*-12-*-*-*-*-*-*-*"
      QuickSwitchFontName="-*-sans-medium-r-*-*-12-*-*-*-*-*-*-*"
      NormalButtonFontName="-*-sans-medium-r-*-*-12-*-*-*-*-*-*-*"
      ActiveButtonFontName="-*-sans-bold-r-*-*-12-*-*-*-*-*-*-*"
      NormalTaskBarFontName="-*-sans-medium-r-*-*-12-*-*-*-*-*-*-*"
      ActiveTaskBarFontName="-*-sans-bold-r-*-*-12-*-*-*-*-*-*-*"
      MinimizedWindowFontName="-*-sans-medium-r-*-*-12-*-*-*-*-*-*-*"
      ListBoxFontName="-*-sans-medium-r-*-*-12-*-*-*-*-*-*-*"
      ToolTipFontName="-*-sans-medium-r-*-*-10-*-*-*-*-*-*-*"
      ClockFontName="-*-sans-bold-r-*-*-12-*-*-*-*-*-*-*"
      ApmFontName="-*-sans-medium-r-*-*-12-*-*-*-*-*-*-*"
      InputFontName="-*-monospace-medium-r-*-*-12-*-*-*-*-*-*-*"
      LabelFontName="-*-sans-bold-r-*-*-12-*-*-*-*-*-*-*"
      
      # Colors (fallback if theme doesn't provide)
      ColorNormalTitleBar="rgb:40/40/40"
      ColorActiveTitleBar="rgb:00/40/80"
      ColorNormalBorder="rgb:60/60/60"
      ColorActiveBorder="rgb:00/80/FF"
      
      # Paths
      DesktopBackgroundCenter=1
      DesktopBackgroundColor="rgb:20/20/20"
      DesktopBackgroundImage=""
      
      # Auto-restart if crashed (important for backup system)
      RestartOnFailure=1
    '';

    environment.etc."icewm/menu".text = ''
      # IceWM Menu Configuration
      # Basic applications menu for backup system
      
      prog Terminal terminal "/run/current-system/sw/bin/kitty"
      prog File Manager folder "/run/current-system/sw/bin/thunar"
      prog Web Browser browser "/run/current-system/sw/bin/firefox"
      prog Text Editor editor "/run/current-system/sw/bin/kate"
      prog System Monitor monitor "/run/current-system/sw/bin/htop"
      
      separator
      menu System {
        prog "Audio Settings" settings "/run/current-system/sw/bin/easyeffects"
        prog "Display Settings" display "/run/current-system/sw/bin/systemsettings5"
        prog "Network Settings" network "/run/current-system/sw/bin/nm-connection-editor"
        separator
        prog "NixOS Config" terminal "kitty -e sudo nano /etc/nixos/configuration.nix"
        prog "Rebuild System" terminal "kitty -e sudo nixos-rebuild switch"
        separator
        prog "Logout" logout "icewm-session --logout"
        prog "Reboot" reboot "systemctl reboot"
        prog "Shutdown" shutdown "systemctl poweroff"
      }
      
      separator
      menu Development {
        prog "Vim" terminal "kitty -e vim"
        prog "Git" terminal "kitty -e git"
        prog "Python" terminal "kitty -e python3"
      }
      
      separator
      menu Multimedia {
        prog "VLC" vlc "/run/current-system/sw/bin/vlc"
        prog "Audacity" audacity "/run/current-system/sw/bin/audacity"
        prog "OBS Studio" obs "/run/current-system/sw/bin/obs"
      }
      
      separator
      menu Graphics {
        prog "GIMP" gimp "/run/current-system/sw/bin/gimp"
        prog "Inkscape" inkscape "/run/current-system/sw/bin/inkscape"
        prog "Blender" blender "/run/current-system/sw/bin/blender"
      }
      
      separator
      menu Games {
        prog "Steam" steam "/run/current-system/sw/bin/steam"
        prog "Doom 3" dhewm3 "/run/current-system/sw/bin/dhewm3"
      }
    '';

    # Create IceWM user directory structure
    system.activationScripts.icewm-config = ''
      mkdir -p /etc/icewm/themes/backup
      cat > /etc/icewm/themes/backup/theme.theme << 'EOF'
# IceWM Backup Theme
# Minimal, professional theme for troubleshooting and backup usage

ThemeDescription="IceWM Backup Theme"
ThemeAuthor="NixOS Configuration"

# Title Bar Colors
TitleBarColors="rgb:40/40/40 rgb:C0/C0/C0 rgb:00/40/80 rgb:FF/FF/FF rgb:FF/FF/FF rgb:FF/FF/FF"

# Border Colors
NormalBorderColor="rgb:60/60/60"
ActiveBorderColor="rgb:00/80/FF"

# Window Title Font
TitleFontName="-*-sans-medium-r-*-*-12-*-*-*-*-*-*-*"
TitleJustify=0
TitleBarHeight=20

# Menu Colors
MenuColors="rgb:20/20/20 rgb:C0/C0/C0 rgb:40/40/40 rgb:FF/FF/FF rgb:FF/FF/FF rgb:FF/FF/FF"

# Menu Font
MenuFontName="-*-sans-medium-r-*-*-12-*-*-*-*-*-*-*"
MenuTitleFontName="-*-sans-bold-r-*-*-12-*-*-*-*-*-*-*"

# Task Bar
TaskBarBgColor="rgb:30/30/30"
TaskBarActiveBgColor="rgb:00/40/80"
TaskBarFontColor="rgb:FF/FF/FF"
TaskBarActiveFontColor="rgb:FF/FF/FF"
TaskBarIconifyMinimizeButtonColor="rgb:A0/A0/A0"
TaskBarMaximizeButtonColor="rgb:A0/A0/A0"
TaskBarCloseButtonColor="rgb:A0/A0/A0"
TaskBarActiveIconifyMinimizeButtonColor="rgb:FF/FF/FF"
TaskBarActiveMaximizeButtonColor="rgb:FF/FF/FF"
TaskBarActiveCloseButtonColor="rgb:FF/FF/FF"

# Clock
ClockFontColor="rgb:FF/FF/FF"
ClockBgColor="rgb:30/30/30"

# Status Bar
StatusFontColor="rgb:FF/FF/FF"
StatusBgColor="rgb:30/30/30"

# Quick Switch
QuickSwitchBgColor="rgb:20/20/20"
QuickSwitchFontColor="rgb:FF/FF/FF"
QuickSwitchActiveBgColor="rgb:00/40/80"
QuickSwitchActiveFontColor="rgb:FF/FF/FF"

# Scrollbar
ScrollBarXColor="rgb:A0/A0/A0"
ScrollBarYColor="rgb:A0/A0/A0"

# Look
ColorGradient=0
ShapeTitleBar=1
TitleBarCentered=1
TitleBarJoinButtons=1
DockAppButtonBevel=1
DockAppButtonBorder=1
EOF
    '';
  };
}
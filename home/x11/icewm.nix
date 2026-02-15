{ config, pkgs, lib, theme ? {}, features ? {}, ... }:

let
  p = theme;
in {
  # ════════════════════════════════════════════════════════════════════════════
  # IceWM - Lightweight Window Manager (X11)
  # ════════════════════════════════════════════════════════════════════════════
  
  home.packages = lib.mkIf (features.enableX11Backup or false) [
    pkgs.icewm
    pkgs.icewm-themes
  ];

  # ════════════════════════════════════════════════════════════════════════════
  # IceWM Theme - Matching current palette
  # ════════════════════════════════════════════════════════════════════════════
  home.file.".config/icewm/theme" = {
    text = ''
# ═══════════════════════════════════════════════════════════════════════════
# IceWM Theme - ${p.name}
# Auto-generated from Nix Home Manager
# ═══════════════════════════════════════════════════════════════════════════

ThemeDescription="${p.name} - DeMoD Workstation"
TitleBarHeight=28

# Colors
ColorNormalBorder="${p.border}"
ColorNormalBorderTitle="${p.borderFocus}"
ColorActiveBorder="${p.borderFocus}"
ColorActiveBorderTitle="${p.accent}"
ColorTitleBar="${p.surface}"
ColorTitleBarText="${p.text}"
ColorTitleBarInactive="${p.bgAlt}"
ColorTitleBarTextInactive="${p.textDim}"

# Gradient backgrounds (if supported)
ColorDesktop="#${lib.removePrefix "#" p.bg}"
ColorNormalTitleButton="${p.surface}"
ColorActiveTitleButton="${p.accent}"
ColorInactiveTitleButton="${p.surfaceAlt}"

# Menu
ColorMenu="${p.surface}"
ColorMenuText="${p.text}"
ColorMenuTitle="${p.surfaceAlt}"
ColorMenuTitleText="${p.accent}"
ColorMenuHighlight="${p.accent}"
ColorMenuHighlightText="${p.textOnAccent}"
ColorMenuShadow="${p.border}"

# Taskbar
ColorTaskBar="${p.bgAlt}"
ColorTaskBarText="${p.text}"
ColorTaskBarClock="${p.accent}"
ColorTaskBarClockText="${p.text}"
ColorTaskBarActiveWorkspace="${p.accent}"
ColorTaskBarActiveWorkspaceText="${p.textOnAccent}"
ColorTaskBarInactiveWorkspace="${p.surface}"
ColorTaskBarInactiveWorkspaceText="${p.textDim}"

# Frames
ColorFrame="${p.surface}"
ColorFrameText="${p.text}"
ColorActiveFrame="${p.accent}"
ColorActiveFrameText="${p.textOnAccent}"
ColorInactiveFrame="${p.surfaceAlt}"
ColorInactiveFrameText="${p.textDim}"

# Dialog
ColorDialog="${p.surface}"
ColorDialogText="${p.text}"

# Tooltip
ColorToolTip="${p.surfaceAlt}"
ColorToolTipText="${p.text}"

# Status
ColorNormalStatus="${p.bg}"
ColorNormalStatusText="${p.text}"

# Quick switch
ColorQuickSwitch="${p.surface}"
ColorQuickSwitchText="${p.text}"
ColorQuickSwitchHighlight="${p.accent}"
ColorQuickSwitchHighlightText="${p.textOnAccent}"

# Borders
BorderWidth=2
BorderColorOuter="${p.border}"
BorderColorInner="${p.borderFocus}"
BorderFrameWidth=2
BorderDialogWidth=3
BorderToolWidth=2

# Title bar
TitleBarJustify=0
TitleBarHorzOffset=0
TitleBarVertOffset=0

# Scrollbar
ScrollBarWidth=16
ScrollBarHeight=16
ScrollBarMargin=2
ScrollBarColor="${p.border}"

# Fonts
MenuFontName="JetBrains Mono:size=11:bold"
StatusFontName="JetBrains Mono:size=11"
TitleFontName="JetBrains Mono:size=11:bold"
ToolTipFontName="JetBrains Mono:size=10"
ClockFontName="JetBrains Mono:size=12:bold"
ApmFontName="JetBrains Mono:size=10"
NormalFontName="JetBrains Mono:size=11"
ActiveFontName="JetBrains Mono:size=11:bold"
MinimizedFontName="JetBrains Mono:size=10"
MaximizedFontName="JetBrains Mono:size=11:bold"
WorkspacesFontName="JetBrains Mono:size=10"
QuickSwitchFontName="JetBrains Mono:size=11:bold"

# Shapes
ShapeFrame="true"
ShapeTitleBar="true"
ShapeButtons="true"

# Sizes
MenuHeight=0
ScrollBarMinExtents=8 8
TitleBarHeight=24
WindowBorderWidth=2
WindowBorderHeight=2
DialogBorderWidth=3
DialogBorderHeight=3
TitleBarHorzPadding=4
TitleBarVertPadding=0
ButtonWidth=20
ButtonHeight=20

# Tiling (if supported)
TileRemote=""
TileHorizontal=""

# Look
DoubleClickTime=500
DoubleClickInterval=250
CursorBlinkRate=500
PointerFocus=1
FocusMode=1
RaiseOnFocus=0
RaiseOnClick=1
RaiseOnClickButton=1
ReqRaiseOnActivate=1
TransientGnome="true"
TransientXde="true"
TransientPlacement="true"
CenteringTransient="false"
SmartPlacement=1
RandomPlacement=1
PositionTransient="true"

# Window list
ShowAllWorkspaces=1
MaxWindowWidth=0
MaxWindowHeight=0
MaxWinListItems=0
ShowTaskBar=1
ShowTray=1
TaskBarAtTop=0
TaskBarHeight=32
TaskBarJustify="left"
TaskBarKeepBelow=0
TaskBarAutoHide=0
TaskBarShowClock=1
TaskBarShowWorkspaces=1
TaskBarShowWindows=1
TaskBarShowTransientWindows=1
TaskBarShowClientArea=1
TaskBarWidthPercent=100
TaskBarAlpha=255

# Tooltip
ShowToolTip=1
ToolTipAlpha=230
ToolTipTimeout=5000
ToolTipShadow=1
ToolTipFontName="JetBrains Mono:size=10"

# Misc
TranslucentWindows=0
OpaqueMove=1
OpaqueResize=1
Compositing=1
CornerRadius=12

# Desktop
DesktopBackgroundCenter=0
DesktopBackgroundImage=""
DesktopBackgroundMode=0
DesktopCount=4
DesktopNames=" 1 "," 2 "," 3 "," 4 "

# Menu
MenuMouseTracking=1
MenuMaxWidth=0
MenuMinWidth=0
CenterMenuOnMonitor=1
SnapToWorkspace=0
SwitchToMapped=1

# Focus
FocusNewWindows=1
FocusOnAppRaise=1
CycleMiniWindows=1
AutoRaise=1
AutoRaiseDelay=500
DelayFocus=0
DelayFocusInterval=500

# Sounds
SoundProgram="play"
    '';
  };

  # ════════════════════════════════════════════════════════════════════════════
  # IceWM Preferences
  # ════════════════════════════════════════════════════════════════════════════
  home.file.".config/icewm/preferences" = {
    text = ''
# ═══════════════════════════════════════════════════════════════════════════
# IceWM Preferences
# ════════════════════════════════════════════════════════════════════════════

# Workspace
WorkspaceNames=" 1 "," 2 "," 3 "," 4 "
WorkspaceCount=4
ForceOneWorkspace=0

# Window management
QuickSwitch=1
QuickSwitchAllMonitors=0
AutoRaise=1
AutoRaiseDelay=500
FocusOnClick=1
FocusOnMap=1
FocusChangesWorkspace=0
PointerWarping=0
RaiseOnFocus=0
RaiseOnClick=1
LowerOnClickWhenFocused=1
ReqRaiseOnActivate=1
TransientGroup=1
TransientPlacement=1

# Tiling
TileOnScreenReserved=0
TileHorizontal="Super+Shift+H"
TileVertical="Super+Shift+V"
TileMaximize="Super+Shift+F"

# Borders
BorderSizeX=2
BorderSizeY=2
TitleBarHeight=24

# Menus
ShowThemesMenu=1
ShowProgramsMenu=1
ShowWorkspacesMenu=1
ShowWindowsMenu=1
ShowHelp=1
ShowRun=1
ShowExit=1
ShowLogout=1
ShowReboot=1
ShowShutdown=1
ShowAbout=1

# Taskbar
ShowTaskBar=1
TaskBarShowWorkspaces=1
TaskBarShowWindows=1
TaskBarShowClients=1
TaskBarShowClock=1
TaskBarShowDate=0
TaskBarShowFreeMemory=0
TaskBarShowLoadAvg=0
TaskBarShowNetSpeed=0
TaskBarShowBattery=1
TaskBarShowBatteryTime=1

# Desktop
DesktopMode=0
DesktopBackgroundImage=""
DesktopBackgroundColor="#${lib.removePrefix "#" p.bg}"

# Look
LookAndFeel=1
Gradients=1
TransparentDocks=1
TransparentTooltips=1

# Icons
UseSmIcons=1
UseHighResIcons=1

# Fonts
IconPath="/usr/share/icons:/usr/share/pixmaps"
IconTheme="Papirus-Dark"
    '';
  };

  # ════════════════════════════════════════════════════════════════════════════
  # IceWM Keys
  # ════════════════════════════════════════════════════════════════════════════
  home.file.".config/icewm/keys" = {
    text = ''
# ═══════════════════════════════════════════════════════════════════════════
# IceWM Keybindings - Super-based, matching Hyprland
# ════════════════════════════════════════════════════════════════════════════

# Terminal
key "Super+Return" "kitty"
key "Super+Shift+Return" "kitty --class floating-term"

# Launcher
key "Super+Space" "wofi --show drun"
key "Super+D" "wofi --show drun"

# Browser
key "Super+B" "brave"
key "Super+Shift+B" "brave --incognito"

# File Manager
key "Super+E" "thunar"
key "Super+Shift+E" "thunar ."

# Window management
key "Super+Q" "icewm -t -close"
key "Super+Shift+Q" "icewm -t -kill"
key "Super+W" "icewm -t -togglefloating"
key "Super+F" "icewm -t -maximize"
key "Super+Shift+F" "icewm -t -fullscreen"
key "Super+P" "icewm -t -pseudo"
key "Super+H" "icewm -t -horiz"
key "Super+V" "icewm -t -vert"

# Focus
key "Super+Left" "icewm -t -focus left"
key "Super+Right" "icewm -t -focus right"
key "Super+Up" "icewm -t -focus up"
key "Super+Down" "icewm -t -focus down"

# Move
key "Super+Shift+Left" "icewm -t -move left"
key "Super+Shift+Right" "icewm -t -move right"
key "Super+Shift+Up" "icewm -t -move up"
key "Super+Shift+Down" "icewm -t -move down"

# Workspace
key "Super+1" "icewm -t -workspace 1"
key "Super+2" "icewm -t -workspace 2"
key "Super+3" "icewm -t -workspace 3"
key "Super+4" "icewm -t -workspace 4"
key "Super+5" "icewm -t -workspace 5"
key "Super+6" "icewm -t -workspace 6"
key "Super+7" "icewm -t -workspace 7"
key "Super+8" "icewm -t -workspace 8"
key "Super+9" "icewm -t -workspace 9"
key "Super+0" "icewm -t -workspace 10"

# Move window to workspace
key "Super+Shift+1" "icewm -t -toworkspace 1"
key "Super+Shift+2" "icewm -t -toworkspace 2"
key "Super+Shift+3" "icewm -t -toworkspace 3"
key "Super+Shift+4" "icewm -t -toworkspace 4"
key "Super+Shift+5" "icewm -t -toworkspace 5"
key "Super+Shift+6" "icewm -t -toworkspace 6"
key "Super+Shift+7" "icewm -t -toworkspace 7"
key "Super+Shift+8" "icewm -t -toworkspace 8"
key "Super+Shift+9" "icewm -t -toworkspace 9"
key "Super+Shift+0" "icewm -t -toworkspace 10"

# Special workspace (scratchpad)
key "Super+S" "icewm -t -togglescratch"
key "Super+Shift+S" "icewm -t -toworkspacescratch"

# Screenshot
key "Print" "xfce4-screenshooter -f"
key "Super+Print" "xfce4-screenshooter -w"
key "Shift+Print" "xfce4-screenshooter -r"

# Lock
key "Super+L" "xdotool key --clearmodifiers Super_L && xlock -mode blank"
key "Super+Shift+L" "xlock -mode blank"

# Volume
key "XF86AudioRaiseVolume" "pactl set-sink-volume @DEFAULT_SINK@ +5%"
key "XF86AudioLowerVolume" "pactl set-sink-volume @DEFAULT_SINK@ -5%"
key "XF86AudioMute" "pactl set-sink-mute @DEFAULT_SINK@ toggle"
key "XF86AudioPlay" "playerctl play-pause"
key "XF86AudioStop" "playerctl stop"
key "XF86AudioNext" "playerctl next"
key "XF86AudioPrev" "playerctl previous"

# Brightness
key "XF86MonBrightnessUp" "xbacklight +5%"
key "XF86MonBrightnessDown" "xbacklight -5%"

# System
key "Super+Escape" "wlogout"
key "Super+Shift+Escape" "icewm -t -exit"

# Reload config
key "Super+Ctrl+R" "icewm -reload"

# Logout
key "Super+X" "wlogout"
    '';
  };

  # ════════════════════════════════════════════════════════════════════════════
  # IceWM Menu
  # ════════════════════════════════════════════════════════════════════════════
  home.file.".config/icewm/menu" = {
    text = ''
# ═══════════════════════════════════════════════════════════════════════════
# IceWM Application Menu
# ════════════════════════════════════════════════════════════════════════════

menu "DeMoD X11"

separator

prog "Terminal" "utilities-terminal" kitty
prog "File Manager" "system-file-manager" thunar
prog "Browser" "web-browser" brave

separator

prog "Text Editor" "accessories-text-editor" nvim
prog "Code" "development" code
prog "Obsidian" "accessories-notes" obsidian

separator

prog "Settings" "preferences-system" plasma-systemsettings
prog "System Monitor" "utilities-system-monitor" gnome-system-monitor

separator

menu "Graphics"
  prog "GIMP" "gimp" gimp
  prog "Inkscape" "inkscape" inkscape
endmenu

menu "Multimedia"
  prog "VLC" "vlc" vlc
  prog "Audacity" "audacity" audacity
endmenu

separator

menu "Accessories"
  prog "Calculator" "gnome-calculator" gnome-calculator
  prog "Archive Manager" "file-roller" file-roller
  prog "Disk Usage" "baobab" baobab
endmenu

separator

prog "Lock Screen" "system-lock-screen" "xlock -mode blank"
prog "Logout" "system-log-out" wlogout

separator

menu "Workspaces"
  prog "Workspace 1" "" icewm -t -workspace 1
  prog "Workspace 2" "" icewm -t -workspace 2
  prog "Workspace 3" "" icewm -t -workspace 3
  prog "Workspace 4" "" icewm -t -workspace 4
endmenu

separator

prog "About IceWM" "help-about" icewm --about
prog "IceWM Control Panel" "preferences-system" icewm --control-panel

endmenu
    '';
  };

  # ════════════════════════════════════════════════════════════════════════════
  # IceWM Startup
  # ════════════════════════════════════════════════════════════════════════════
  home.file.".config/icewm/startup" = {
    executable = true;
    text = ''
#!/bin/bash
# ════════════════════════════════════════════════════════════════════════════
# IceWM Startup Script
# ════════════════════════════════════════════════════════════════════════════

# Run as daemon
export ICEWM_PRIVCFG="$HOME/.icewm"

# Enable compositing if available
picom --config ~/.config/picom.conf &

# Start notification daemon
dunst &

# Start system tray
nm-applet --indicator &
udiskie --automount --notify &

# Clipboard
clipit &

# Set wallpaper (using nitrogen or feh)
feh --bg-fill ~/.config/hypr/wallpapers/default.png &

# Load X resources
xrdb -merge ~/.Xresources &

# Apply theme to applications
eval $(gnome-keyring-daemon --start --components=secrets)
export SSH_AUTH_SOCK

# Cursor
xsetroot -cursor_name left_ptr &

# Done
echo "IceWM started"
    '';
  };

  # ════════════════════════════════════════════════════════════════════════════
  # IceWM WinOptions (per-application settings)
  # ════════════════════════════════════════════════════════════════════════════
  home.file.".config/icewm/winoptions" = {
    text = ''
# ════════════════════════════════════════════════════════════════════════════
# IceWM Window Options
# ════════════════════════════════════════════════════════════════════════════

# Floating windows
thunar: float
nautilus: float
pavucontrol: float
blueman-manager: float
nm-connection-editor: float
gnome-calculator: float
gnome-system-monitor: float
vlc: float

# Fullscreen
mpv: fullscreen

# Workspace assignments
steam: workspace 9
discord: workspace 5
thunderbird: workspace 5

# No focus
steam_app_*: nofocus

# Always on top
telegram-desktop: layer=above
    '';
  };
}

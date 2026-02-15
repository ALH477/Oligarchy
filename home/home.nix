{ config, pkgs, lib, inputs, username ? "asher", features ? {}, theme ? "demod", ... }:

let
  # Validate inputs
  _validation = lib.assertions [
    {
      assertion = username != null && username != "";
      message = "DeMoD: username must be a non-empty string";
    }
    {
      assertion = lib.elem theme [
        "demod" "catppuccin" "nord" "rosepine" 
        "gruvbox" "dracula" "tokyo" "phosphor"
      ];
      message = "DeMoD: theme '${theme}' is not valid. Choose from: demod, catppuccin, nord, rosepine, gruvbox, dracula, tokyo, phosphor";
    }
    {
      assertion = lib.elem (features.sessionType or "wayland") [ "wayland" "x11" ];
      message = "DeMoD: sessionType must be 'wayland' or 'x11'";
    }
    {
      assertion = lib.elem (features.x11Wm or "icewm") [ "icewm" "leftwm" "dwm" "plasma-x11" ];
      message = "DeMoD: x11Wm must be one of: icewm, leftwm, dwm, plasma-x11";
    }
  ];
  
  # Merge provided features with defaults
  defaultFeatures = {
    hasBattery = lib.pathExists "/sys/class/power_supply/BAT0";
    hasTouchpad = lib.pathExists "/dev/input/event0" || lib.pathExists "/dev/input/mouse0";
    hasBacklight = lib.pathExists "/sys/class/backlight";
    hasBluetooth = lib.pathExists "/sys/class/bluetooth";
    enableDev = true;
    enableGaming = false;
    enableAudio = true;
    enableDCF = false;
    enableAIStack = false;
    sessionType = "wayland";
    x11Wm = "icewm";
  };
  
  # Merge user-provided features with defaults (user-provided takes precedence)
  finalFeatures = defaultFeatures // features;
  
  # username parameter with default
  user = username;
  homeDirectory = "/home/${user}";
  
  # Import theme system
  themeSystem = import ./themes { inherit lib; };
  
  # Validate theme exists in theme system
  _themeValidation = lib.assertions [
    {
      assertion = lib.hasAttr theme themeSystem.palettes;
      message = "DeMoD: theme '${theme}' not found in theme system";
    }
  ];
  
  # Active theme and colors (from theme system)
  activeTheme = themeSystem.palettes.${theme};
  themeName = theme;
  
in {
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
    
    # Placeholder directories
    file."Pictures/Screenshots/.keep".text = "";
    file.".config/hypr/wallpapers/.keep".text = "";
    file.".local/bin/.keep".text = "";
  };
  
  # Cursor configuration
  home.pointerCursor = {
    gtk.enable = true;
    x11.enable = true;
    package = pkgs.bibata-cursors;
    name = "idTech4";
    size = 24;
  };
  
  # Font configuration
  fonts.fontconfig.enable = true;
  
  # Import all modules
  imports = [
    ./packages.nix
    ./terminal            # Kitty terminal
    ./waybar
    ./hyprland
    ./shell
    ./apps
    ./scripts
    ./profiles
    # ./x11               # Optional: uncomment for X11 (icewm, leftwm)
  ];
  
  # Pass theme and features to all modules
  _module.args = {
    theme = activeTheme;  # The palette object with all colors
    features = finalFeatures;
    inherit username homeDirectory;
  };
  
  programs.home-manager.enable = true;
}

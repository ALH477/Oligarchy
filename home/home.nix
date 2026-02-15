{ config, pkgs, lib, inputs, username ? "asher", ... }:

let
  # username parameter with default
  user = username;
  homeDirectory = "/home/${user}";
  
  # Import theme system
  themeSystem = import ./themes { inherit lib; };
  
  # Feature flags - auto-detected + user overrides
  features = {
    hasBattery = lib.pathExists "/sys/class/power_supply/BAT0";
    hasTouchpad = lib.pathExists "/dev/input/event0" || lib.pathExists "/dev/input/mouse0";
    hasBacklight = lib.pathExists "/sys/class/backlight";
    hasBluetooth = lib.pathExists "/sys/class/bluetooth";
    enableDev = true;
    enableGaming = false;
    enableAudio = true;
    enableDCF = false;
    enableAIStack = false;
  };
  
  # Active theme and colors (from theme system)
  theme = themeSystem.activePalette;
  
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
    inherit theme features username homeDirectory;
  };
  
  programs.home-manager.enable = true;
}

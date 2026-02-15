{ config, pkgs, lib, ... }:

let
  user = "asher";
  homeDirectory = "/home/${user}";
  
  themeSystem = import ./themes { inherit lib; };
  activeTheme = themeSystem.palettes.demod;
  p = activeTheme;
  
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

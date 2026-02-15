{ config, pkgs, lib, ... }:

{
  home = {
    homeDirectory = "/home/asher";
    username = "asher";
    stateVersion = "25.11";
    
    sessionVariables = {
      EDITOR = "nvim";
      BROWSER = "brave";
      TERMINAL = "kitty";
    };
  };

  programs.home-manager.enable = true;
}

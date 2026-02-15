# Example NixOS Configuration for Oligarchy Plymouth Theme
# Multiple methods shown below

# ═══════════════════════════════════════════════════════════════════════════
# Method 1: Flake Module (RECOMMENDED)
# ═══════════════════════════════════════════════════════════════════════════

# flake.nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    oligarchy-plymouth.url = "path:./oligarchy-theme";
  };

  outputs = { nixpkgs, oligarchy-plymouth, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        oligarchy-plymouth.nixosModules.default
        {
          boot.plymouth.oligarchy = {
            enable = true;
            wallpaper = ./wallpaper.jpg;  # Optional
            quiet = true;
          };
        }
      ];
    };
  };
}

# ═══════════════════════════════════════════════════════════════════════════
# Method 2: Traditional Configuration (Non-Flake)
# ═══════════════════════════════════════════════════════════════════════════

# Add this to your configuration.nix
{ config, pkgs, lib, ... }:

let
  oligarchy-theme = pkgs.callPackage ./oligarchy-theme/package.nix {};
in
{
  # Enable Plymouth with Oligarchy theme
  boot.plymouth = {
    enable = true;
    theme = "oligarchy";
    themePackages = [ oligarchy-theme ];
  };

  # Optional: Enable silent boot for cleaner experience
  boot.kernelParams = [ "quiet" ];
  
  # Optional: Disable systemd status messages
  boot.consoleLogLevel = 3;
}

{
  description = "Oligarchy NixOS: Optimized for Framework 16 with DeMoD-LISP SDK";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/*";
    nixos-hardware.url = "github:NixOS/nixos-hardware";
    fw-fanctrl.url = "github:TamtamHero/fw-fanctrl/packaging/nix";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, determinate, nixos-hardware, fw-fanctrl, disko, ... }:
  let
    system = "x86_64-linux";
    lib = nixpkgs.lib;
  in {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = { inherit nixpkgs-unstable lib; };
      modules = [
        determinate.nixosModules.default
        nixos-hardware.nixosModules.framework-16-7040-amd
        fw-fanctrl.nixosModules.default
        ./hardware-configuration.nix
        ./configuration.nix
      ];
    };

    nixosConfigurations.iso = nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = { inherit nixpkgs-unstable lib; };
      modules = [
        "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-graphical-base.nix"  # Lighter base than plasma5
        "${nixpkgs}/nixos/modules/installer/cd-dvd/channel.nix"
        determinate.nixosModules.default
        nixos-hardware.nixosModules.framework-16-7040-amd  # Keep if needed for live hardware support
        fw-fanctrl.nixosModules.default  # Keep if needed for live
        disko.nixosModules.disko
        ({ config, pkgs, lib, ... }: {
          nixpkgs.overlays = [
            (final: prev: {
              unstable = import nixpkgs-unstable {
                system = prev.system;
                config.allowUnfree = true;
              };
              calamares-nixos-extensions = prev.calamares-nixos-extensions.overrideAttrs (old: {
                postPatch = (old.postPatch or "") + ''
                  substituteInPlace modules/nixos/module.py \
                    --replace 'imports = [\n    ./hardware-configuration.nix\n  ];' 'imports = [\n    ./hardware-configuration.nix\n    ./configuration.nix\n  ];'
                '';
              });
            })
          ];

          # Enable minimal graphical environment for Calamares (lightweight WM instead of full DE)
          services.xserver.enable = true;
          services.xserver.displayManager.sddm.enable = true;  # Or lightdm for lighter
          services.xserver.desktopManager.plasma5.enable = lib.mkForce false;  # Disable heavy Plasma
          services.xserver.windowManager.i3.enable = true;  # Lightweight WM

          # Enable Calamares installer
          services.calamares.enable = true;

          # Minimal packages for live environment (add only essentials)
          environment.systemPackages = with pkgs; [
            calamares-nixos-extensions  # Ensure Calamares extensions
            parted  # For partitioning if needed
            # Avoid adding your long list here; it's for target only
          ];

          # Disable unnecessary live services to save space
          documentation.enable = false;  # Remove docs
          documentation.nixos.enable = false;
          services.udisks2.enable = false;  # If not needed
          # Add more disables as needed (e.g., printing, bluetooth if unused in live)

          environment.etc."nixos-flake".source = self;

          services.calamares.settings = {
            exec = [
              "prepare"
              "partition"
              "mount"
              "shellprocess@copycustom"
              "nixos"
              "shellprocess@install"
              "unmount"
            ];
            moduleConfigurations.copycustom = {
              type = "shellprocess";
              timeout = -1;
              commands = [
                "cp -r /etc/nixos-flake/configuration.nix /mnt/etc/nixos/"
              ];
            };
          };

          nix.settings.experimental-features = [ "nix-command" "flakes" ];

          # Better compression for smaller ISO (zstd is efficient)
          isoImage.squashfsCompression = "zstd -Xcompression-level 15";
        })
      ];
    };
  };
}

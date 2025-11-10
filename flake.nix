{
  description = "Oligarchy NixOS: Optimized for Framework 16 with DeMoD-LISP SDK";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-hardware.url = "github:NixOS/nixos-hardware";
    fw-fanctrl.url = "github:TamtamHero/fw-fanctrl/packaging/nix";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, nixos-hardware, fw-fanctrl, disko, ... }:
  let
    system = "x86_64-linux";
    lib = nixpkgs.lib;
  in {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = { inherit nixpkgs-unstable lib; };
      modules = [
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
        "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-graphical-base.nix"  # Lightweight base
        "${nixpkgs}/nixos/modules/installer/cd-dvd/channel.nix"
        nixos-hardware.nixosModules.framework-16-7040-amd  # For live hardware support
        fw-fanctrl.nixosModules.default  # For live fan control if needed
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
                  substituteInPlace modules/nixos/main.py \
                    --replace 'imports = [\n    ./hardware-configuration.nix\n  ];' 'imports = [\n    ./hardware-configuration.nix\n    ./configuration.nix\n  ];'
                '';
              });
            })
          ];

          # Minimal graphical environment (lightweight DM + WM)
          services.xserver.enable = true;
          services.xserver.displayManager.lightdm.enable = true;  # Lighter than SDDM
          services.xserver.windowManager.i3.enable = true;

          # Minimal packages for live environment
          environment.systemPackages = with pkgs; [
            calamares-nixos  # The Calamares installer package
            calamares-nixos-extensions  # Extensions (with your patch)
            parted  # For partitioning
          ];

          # Disable unnecessary live features
          documentation.enable = false;
          documentation.nixos.enable = false;
          services.udisks2.enable = false;
          services.printing.enable = false;

          environment.etc."nixos-flake".source = self;

          # Provide Calamares settings as YAML
          environment.etc."calamares/settings.conf".text = ''
            ---
            modules-search: [ local, files ]
            exec:
              - prepare
              - partition
              - mount
              - shellprocess@copycustom
              - nixos
              - shellprocess@install
              - unmount
            moduleConfigurations:
              copycustom:
                type: shellprocess
                timeout: -1
                commands:
                  - cp -r /etc/nixos-flake/configuration.nix /mnt/etc/nixos/
          '';

          # Autostart Calamares on login for convenience
          environment.etc."xdg/autostart/calamares.desktop".text = ''
            [Desktop Entry]
            Type=Application
            Exec=calamares -d
            Name=Install NixOS
            NoDisplay=false
          '';

          nix.settings.experimental-features = [ "nix-command" "flakes" ];

          # Better compression for smaller ISO
          isoImage.squashfsCompression = "zstd -Xcompression-level 15";
        })
      ];
    };
  };
}

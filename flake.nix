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
        "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-graphical-base.nix"
        "${nixpkgs}/nixos/modules/installer/cd-dvd/channel.nix"
        determinate.nixosModules.default
        nixos-hardware.nixosModules.framework-16-7040-amd
        fw-fanctrl.nixosModules.default
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

          services.xserver.enable = true;
          services.xserver.displayManager.lightdm.enable = true;
          services.xserver.windowManager.i3.enable = true;

          environment.systemPackages = with pkgs; [
            calamares-nixos
            calamares-nixos-extensions
            parted
          ];

          documentation.enable = false;
          documentation.nixos.enable = false;
          services.udisks2.enable = lib.mkForce false;  # Prioritize to override fwupd
          services.printing.enable = false;

          environment.etc."nixos-flake".source = self;

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

          environment.etc."xdg/autostart/calamares.desktop".text = ''
            [Desktop Entry]
            Type=Application
            Exec=calamares -d
            Name=Install NixOS
            NoDisplay=false
          '';

          nix.settings.experimental-features = [ "nix-command" "flakes" ];

          isoImage.squashfsCompression = "zstd -Xcompression-level 15";
        })
      ];
    };
  };
}

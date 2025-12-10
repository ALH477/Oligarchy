{
  description = "Oligarchy NixOS – Framework 16 + DeMoD-LISP + ArchibaldOS-DSP kexec coprocessor";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";

    nixos-hardware.url = "github:NixOS/nixos-hardware";
    fw-fanctrl.url = "github:TamtamHero/fw-fanctrl/packaging/nix";
    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    # Pull ArchibaldOS so we can reference its built DSP image directly
    archibaldos.url = "github:ALH477/ArchibaldOS";
    archibaldos.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, nixos-hardware, fw-fanctrl, disko, archibaldos, ... }:
  let
    system = "x86_64-linux";
    lib = nixpkgs.lib;
  in {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = { inherit nixpkgs-unstable lib archibaldos; };
      modules = [
        nixos-hardware.nixosModules.framework-16-7040-amd
        fw-fanctrl.nixosModules.default
        disko.nixosModules.disko

        ./hardware-configuration.nix
        ./configuration.nix
        ./modules/archibaldos-dsp-vm.nix   # ← your new DSP VM module lives here
      ];
    };

    nixosConfigurations.iso = nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = { inherit nixpkgs-unstable lib archibaldos; };
      modules = [
        "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-graphical-plasma5.nix"
        "${nixpkgs}/nixos/modules/installer/cd-dvd/channel.nix"

        nixos-hardware.nixosModules.framework-16-7040-amd
        fw-fanctrl.nixosModules.default
        disko.nixosModules.disko

        # Import the exact same modules the real system uses → the ISO will behave identically
        ./configuration.nix
        ./modules/archibaldos-dsp-vm.nix

        ({ config, pkgs, ... }: {
          # Calamares tweaks so the installed system gets your full config
          environment.etc."nixos-flake".source = self;

          environment.etc."calamares/settings.conf".text = ''
            ---
            modules-search: [ local ]
            exec:
              - prepare
              partition
              mount
              shellprocess@copycustom
              nixos
              unmount
            moduleConfigurations:
              copycustom:
                type: shellprocess
                timeout: -1
                commands:
                  - cp -r /etc/nixos-flake/{configuration.nix,hardware-configuration.nix,modules} /mnt/etc/nixos/
          '';

          environment.etc."xdg/autostart/calamares.desktop".text = ''
            [Desktop Entry]
            Type=Application
            Exec=calamares -d
            Name=Install Oligarchy NixOS
            NoDisplay=false
          '';

          nix.settings.experimental-features = [ "nix-command" "flakes" ];
          isoImage.squashfsCompression = "zstd -Xcompression-level 15";
        })
      ];
    };
  };
}

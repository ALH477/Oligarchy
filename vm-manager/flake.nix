{
  description = "VM Manager - Hybrid low-overhead VM management for Oligarchy";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    quickemu.url = "github:quickemu-project/quickemu";
  };

  outputs = { self, nixpkgs, quickemu, ... }:
    let
      system = "x86_64-linux";
    in {
      nixosModules = {
        # Quickemu-based VMs for sandbox and kali
        quickemu-vm = import ./modules/quickemu-vm.nix;

        # Enhanced DSP VM using QEMU with ArchibaldOS + NETJACK
        dsp-vm = import ./modules/dsp-vm.nix;

        # Pre-configured VM instances
        coding-sandbox = import ./config/sandbox.nix;
        kali-linux = import ./config/kali.nix;
        openwrt-router = import ./config/openwrt-router.nix;
      };

      packages.${system} = {
        # Quickemu wrapper with nix-shell integration
        quickemu-wrapper = quickemu.packages.${system}.quickemu.overrideAttrs (old: {
          buildInputs = old.buildInputs or [] ++ [ nixpkgs.legacyPackages.${system}.bash nixpkgs.legacyPackages.${system}.coreutils ];
        });
      };
    };
}

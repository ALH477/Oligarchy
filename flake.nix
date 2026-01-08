{
  description = "Determinate NixOS Setup for R&D with Multiple Kernels, Desktops, and DeMoD Communication Framework";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/*";
    nixos-hardware.url = "github:NixOS/nixos-hardware";
    fw-fanctrl.url = "github:TamtamHero/fw-fanctrl/packaging/nix";
    demod-ip-blocker.url = "git+https://github.com/ALH477/DeMoD-IP-Blocker.git";
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, determinate, nixos-hardware, fw-fanctrl, ... }:
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
        ({ config, lib, ... }: {
          options = {
            hardware.framework.enable = lib.mkEnableOption "Framework 16-inch 7040 AMD support";
            hardware.fw-fanctrl.enable = lib.mkEnableOption "Framework fan control";
          };
          config = {
            nixpkgs.overlays = [
              (final: prev: {
                unstable = import nixpkgs-unstable {
                  system = prev.system;
                  config.allowUnfree = true;
                };
              })
            ];
            hardware.framework.enable = true;
            hardware.fw-fanctrl.enable = true;
          };
        })
      ];
    };
  };
}

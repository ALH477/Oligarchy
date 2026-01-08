{
  description = "Determinate NixOS Setup for R&D";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/*";
    nixos-hardware.url = "github:NixOS/nixos-hardware";
    fw-fanctrl.url = "github:TamtamHero/fw-fanctrl/packaging/nix";
    demod-ip-blocker.url = "git+https://github.com/ALH477/DeMoD-IP-Blocker.git";
    minecraft.url = "github:ALH477/NixOS-MineCraft";
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, determinate, nixos-hardware, fw-fanctrl, demod-ip-blocker, minecraft ... }@inputs:
  let
    system = "x86_64-linux";
  in {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = { inherit inputs nixpkgs-unstable; };
      modules = [
        determinate.nixosModules.default
        nixos-hardware.nixosModules.framework-16-7040-amd
        fw-fanctrl.nixosModules.default
        demod-ip-blocker.nixosModules.default
        minecraft.nixosModules.default
        
        # Point to your external configuration file
        ./configuration.nix
        
        
      ];
    };
  };
}

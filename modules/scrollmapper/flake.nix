{
  description = "Oligarchy Scrollmapper module — low-footprint Orthodox-canon reader with a boot-dialogue verse";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      mkPkg = system: translation:
        nixpkgs.legacyPackages.${system}.callPackage ./package.nix { inherit translation; };
    in
    {
      packages = forAllSystems (system: rec {
        default = kjva;
        kjva = mkPkg system "KJVA";
        kjv = mkPkg system "KJV";
        cpdv = mkPkg system "CPDV";
        asv = mkPkg system "ASV";
        bsb = mkPkg system "BSB";
      });

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/scrollmapper";
        };
        daily = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/scrollmapper-daily";
        };
      });

      nixosModules.scrollmapper = import ./module.nix self;
      nixosModules.default = self.nixosModules.scrollmapper;

      overlays.default = final: prev: {
        oligarchy-scrollmapper = final.callPackage ./package.nix { translation = "KJVA"; };
      };
    };
}

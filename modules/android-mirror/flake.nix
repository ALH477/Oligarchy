{
  description = "USB scrcpy phone-mirror: low-latency Android game display";

  # Followed by the parent lock (`android-mirror.inputs.nixpkgs.follows = "nixpkgs"`).
  # Extra inputs here are NOT passed by the parent unless followed or re-locked
  # at the repo root — do not add flake-utils.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
          suite = pkgs.callPackage ./package.nix { };
        in
        {
          default = suite;
          android-mirror = suite;
          phone-mirror = suite;
        }
      );

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/phone-mirror";
        };
        phone-mirror = self.apps.${system}.default;
      });

      nixosModules.default = import ./nixos-module.nix self;
      nixosModules.android-mirror = self.nixosModules.default;
    };
}

{
  description = "Windscribe Desktop-App: the official VPN client, helper daemon and CLI";

  # Followed by the parent lock (`windscribe-app.inputs.nixpkgs.follows = "nixpkgs"`).
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
          app = pkgs.callPackage ./pkgs/windscribe-desktop.nix { };
        in
        {
          default = app;
          windscribe-desktop = app;
        }
      );

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/windscribe";
        };
        windscribe-cli = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/windscribe-cli";
        };
      });

      nixosModules.default = import ./nixos-module.nix self;
      nixosModules.windscribe-app = self.nixosModules.default;
    };
}

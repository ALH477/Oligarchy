# services.oligarchyHaven — Haven, a self-hosted private-chat Discord alternative.
#
# AGPL-3.0 upstream. Haven's SOURCE IS NEVER VENDORED into this tree: the
# package below fetches an immutable release tag at build time, so the AGPL
# code never lands in the repo and the module/package glue here stays DeMoD
# BSD-3-Clause (see REUSE.toml). Deploying an UNMODIFIED build of an AGPL
# network service imposes no source-publication obligation; if a fork patches
# the package derivation, the AGPL §13 offer-of-source note must be added to
# modules/haven/README.md. See that file for the full licence posture.
#
# Followed by the parent lock (`haven.inputs.nixpkgs.follows = "nixpkgs"`).
# Extra inputs here are NOT passed by the parent unless followed or re-locked
# at the repo root — do not add flake-utils.
{
  description = "Haven — self-hosted private chat (AGPL-3.0), sandboxed NixOS module";

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
        in
        {
          default = pkgs.callPackage ./packages/haven.nix { };
          haven = self.packages.${system}.default;
        }
      );

      nixosModules.default = import ./nixos-module.nix self;
      nixosModules.haven = self.nixosModules.default;
    };
}

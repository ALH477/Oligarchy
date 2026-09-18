{
  description = "oligarchy-vault: user-data encryption for Oligarchy (age blobs, fscrypt dirs, gocryptfs overlays)";

  # Only nixpkgs. The parent lock follows this input; any OTHER input added
  # here is NOT supplied by the parent unless it is also followed, and an
  # unfollowed input silently pins a second nixpkgs. No flake-utils.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

  # LOAD-BEARING: the outputs function takes exactly { self, nixpkgs, ... }.
  # A path subflake is called with the arguments the PARENT lock provides; an
  # extra *required* argument here makes the whole OS evaluation die with
  # "called without required argument", not just this flake.
  outputs = { self, nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # Bare module function, not a flake-aware wrapper: the parent's pkgs,
      # lib and config are the ones that matter, and the CLI is built with
      # callPackage inside the module so it tracks the parent's nixpkgs.
      nixosModules.default = import ./nixos-module.nix;
      nixosModules.vault = self.nixosModules.default;

      packages = forAllSystems (pkgs:
        let
          oligarchy-vault = pkgs.callPackage ./pkgs/oligarchy-vault.nix { };
        in
        {
          inherit oligarchy-vault;
          default = oligarchy-vault;
        });
    };
}

{
  description = "oligarchy-forge — sandboxed coding-agent runner (schema + engine + CLI)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem
      (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # Built as one workspace binary (forge-cli depends on forge-core)
          # via a shared, committed Cargo.lock — mirrors modules/mcp-servers.
          oligarchy-forge = pkgs.rustPlatform.buildRustPackage {
            pname = "oligarchy-forge";
            version = "0.1.0";
            src = ./.;
            cargoLock.lockFile = ./Cargo.lock;
            nativeBuildInputs = [ pkgs.pkg-config ];

            # Only the CLI binary is a build target; forge-core has no bin.
            buildAndTestSubset = [ "--package" "forge-cli" ];

            meta = with pkgs.lib; {
              description = "Sandboxed coding-agent runner: TOML schema -> generated flake.nix -> nix build -> podman/docker run";
              license = licenses.mit;
              platforms = platforms.linux;
              mainProgram = "oligarchy-forge";
            };
          };
        in
        {
          packages.default = oligarchy-forge;
          packages.oligarchy-forge = oligarchy-forge;

          devShells.default = pkgs.mkShell {
            packages = with pkgs; [ rustc cargo pkg-config ];
          };
        }
      ) // {
      # NixOS module surface — consumed by the top-level flake.
      nixosModules.default = import ./nixos-module.nix;
      nixosModules.oligarchy-forge = self.nixosModules.default;
    };
}

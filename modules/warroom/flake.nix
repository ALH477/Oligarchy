{
  description = "warroom — Oligarchy War Room, a unified Ratatui command center";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem
      (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};

          # Built as one workspace binary (warroom-tui depends on warroom-core)
          # via a shared, committed Cargo.lock — mirrors modules/oligarchy-forge.
          warroom = pkgs.rustPlatform.buildRustPackage {
            pname = "warroom";
            version = "0.1.0";
            src = ./.;
            cargoLock.lockFile = ./Cargo.lock;
            nativeBuildInputs = [ pkgs.pkg-config ];

            # Only the TUI crate is a build target; warroom-core has no bin.
            buildAndTestSubset = [ "--package" "warroom-tui" ];

            meta = with pkgs.lib; {
              description = "Oligarchy War Room: unified Ratatui command center over DSP, mesh, perimeter and the oligarchy-ctl action registry";
              license = licenses.mit;
              platforms = platforms.linux;
              # The crate is warroom-tui; the binary it ships is `warroom`.
              mainProgram = "warroom";
            };
          };
        in
        {
          packages.default = warroom;
          packages.warroom = warroom;

          devShells.default = pkgs.mkShell {
            packages = with pkgs; [ rustc cargo clippy rustfmt pkg-config ];
          };
        }
      ) // {
      # NixOS module surface — consumed by the top-level flake.
      nixosModules.default = import ./nixos-module.nix;
      nixosModules.warroom = self.nixosModules.default;
    };
}

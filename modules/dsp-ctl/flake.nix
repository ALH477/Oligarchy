{
  description = "dsp-ctl — TUI/CLI for ArchibaldOS DSP Coprocessor VM management";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};

        dsp-ctl = pkgs.rustPlatform.buildRustPackage {
          pname = "dsp-ctl";
          version = "1.0.0";

          src = ./.;

          cargoHash = "sha256-4cwmzWTtJ/Hj3cNQea1ZKBNf+kRtebIf0WY9vvvnStw=";

          nativeBuildInputs = with pkgs; [ pkg-config ];
          buildInputs = with pkgs; [ ];

          meta = with pkgs.lib; {
            description = "DSP Coprocessor VM Control — TUI/CLI for ArchibaldOS DSP VM";
            license = licenses.mit;
            platforms = platforms.linux;
          };
        };
      in {
        packages.default = dsp-ctl;
        packages.dsp-ctl = dsp-ctl;

        devShells.default = pkgs.mkShell {
          packages = with pkgs; [ rustc cargo pkg-config ];
        };
      }) // {
        nixosModules.dsp-ctl = { pkgs, ... }: {
          environment.systemPackages = [
            self.packages.x86_64-linux.dsp-ctl
          ];
        };
      };
}

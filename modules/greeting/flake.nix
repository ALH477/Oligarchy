{
  description = "Oligarchy NixOS Welcome Greeting - CLI and TUI with Kitty image support";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = nixpkgs.legacyPackages.${system};
        
        oligarchy-greeting = pkgs.rustPlatform.buildRustPackage {
          pname = "oligarchy-greeting";
          version = "1.0.0";
          
          src = ./.;
          
          cargoHash = pkgs.lib.fakeSha256;
          
          nativeBuildInputs = with pkgs; [
            pkg-config
          ];
          
          buildInputs = with pkgs; [
            # Runtime dependencies
          ];
          
          postInstall = ''
            # Create directories for images
            mkdir -p $out/share/oligarchy
          '';
          
          meta = with pkgs.lib; {
            description = "Oligarchy NixOS Welcome Greeting with Kitty image support";
            license = licenses.mit;
            platforms = platforms.linux;
            maintainers = [ ];
          };
        };
        
      in {
        packages = {
          default = oligarchy-greeting;
          oligarchy-greeting = oligarchy-greeting;
        };
        
        devShells.default = pkgs.mkShell {
          inputsFrom = [ oligarchy-greeting ];
          packages = with pkgs; [
            cargo
            rustc
            rustfmt
            clippy
            rust-analyzer
          ];
        };
      }
    ) // {
      nixosModules.greeting = import ./greeting.nix self;
      nixosModules.default = self.nixosModules.greeting;
    };
}

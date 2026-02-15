{
  description = "Oligarchy Plymouth Theme - DeMoD Radical Retro-Tech boot splash for NixOS";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }:
    let
      # Systems to support
      supportedSystems = [ "x86_64-linux" "aarch64-linux" ];
      
      # Helper to generate an attribute set for each system
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      
      # Import nixpkgs for each system
      nixpkgsFor = forAllSystems (system: import nixpkgs { inherit system; });
    in
    {
      # Package output - the theme itself
      packages = forAllSystems (system:
        let
          pkgs = nixpkgsFor.${system};
        in
        {
          default = self.packages.${system}.oligarchy-plymouth-theme;
          
          oligarchy-plymouth-theme = pkgs.callPackage ./package.nix { };
        });

      # NixOS module
      nixosModules = {
        default = self.nixosModules.oligarchy-plymouth;
        
        oligarchy-plymouth = { config, lib, pkgs, ... }: {
          imports = [ ./module.nix ];
          
          # Make the theme package available
          config = lib.mkIf config.boot.plymouth.oligarchy.enable {
            boot.plymouth.themePackages = [ 
              self.packages.${pkgs.system}.oligarchy-plymouth-theme 
            ];
          };
        };
      };

      # Development shell
      devShells = forAllSystems (system:
        let
          pkgs = nixpkgsFor.${system};
        in
        {
          default = pkgs.mkShell {
            buildInputs = with pkgs; [
              plymouth
              imagemagick
            ];
            
            shellHook = ''
              echo "Oligarchy Plymouth Theme Development Shell"
              echo "========================================="
              echo ""
              echo "Available commands:"
              echo "  plymouth --show-splash    # Test theme"
              echo "  convert ...               # Create wallpapers"
              echo ""
              echo "Theme files in: $(pwd)"
            '';
          };
        });

      # Formatter for nix files
      formatter = forAllSystems (system: nixpkgsFor.${system}.nixpkgs-fmt);
    };
}

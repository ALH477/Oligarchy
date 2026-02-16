{
  description = "Oligarchy NixOS greeting module with TUI - The War Room";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs = { self, nixpkgs }: 
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
    in
    {
      nixosModules.greeting = import ./greeting.nix self;
      nixosModules.default = self.nixosModules.greeting;
      
      packages = forAllSystems (system:
        let
          pkgs = nixpkgs.legacyPackages.${system};
        in
        {
          welcome-tui = pkgs.python3Packages.buildPythonApplication {
            pname = "oligarchy-welcome-tui";
            version = "1.0.0";
            
            src = ./.;
            
            propagatedBuildInputs = with pkgs.python3Packages; [
              textual
            ];
            
            installPhase = ''
              mkdir -p $out/bin $out/share/welcome-tui
              cp welcome_tui.py $out/share/welcome-tui/
              
              cat > $out/bin/welcome-tui <<EOF
              #!${pkgs.bash}/bin/bash
              exec ${pkgs.python3}/bin/python3 $out/share/welcome-tui/welcome_tui.py "\$@"
              EOF
              chmod +x $out/bin/welcome-tui
            '';
            
            meta = with pkgs.lib; {
              description = "Oligarchy NixOS Welcome TUI - The War Room";
              license = licenses.mit;
              platforms = platforms.linux;
            };
          };
          
          default = self.packages.${system}.welcome-tui;
        });
    };
}

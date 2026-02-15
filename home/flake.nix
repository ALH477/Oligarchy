{
  description = "DeMoD - Modular Nix Home Manager Configuration";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    hyprland.url = "github:hyprwm/Hyprland";
    hyprland.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = { self, nixpkgs, home-manager, ... } @ inputs:
    let
      lib = nixpkgs.lib;
      
      # System configurations
      systems = [ "x86_64-linux" "aarch64-linux" ];
      
      # Common overlay for all systems
      overlay = final: prev: {
        # Custom packages or overrides can go here
      };
    in
    {
      # NixOS module for easy importing
      nixosModules.demod = { config, pkgs, ... }:
        let
          cfg = config.programs.demod;
        in
        {
          options.programs.demod = {
            enable = lib.mkEnableOption "DeMoD home manager configuration";
            
            username = lib.mkOption {
              type = lib.types.str;
              default = "asher";
              description = "Username for the home configuration";
            };
            
            features = lib.mkOption {
              type = lib.types.attrsOf lib.types.bool;
              default = {
                enableDev = true;
                enableGaming = false;
                enableAudio = true;
                enableDCF = false;
                enableAIStack = false;
                sessionType = "wayland";
              };
              description = "Feature flags for the configuration";
            };
            
            theme = lib.mkOption {
              type = lib.types.str;
              default = "demod";
              description = "Theme to use";
            };
          };
          
          config = lib.mkIf cfg.enable {
            home-manager.users.${cfg.username} = import ./home.nix {
              inherit (inputs) nixpkgs;
              username = cfg.username;
              features = cfg.features;
              theme = cfg.theme;
            };
          };
        };
      
      # Home manager configurations for each system
      homeConfigurations = lib.genAttrs systems (system:
        let
          pkgs = import nixpkgs {
            inherit system;
            overlays = [ overlay ];
          };
          
          # Default configuration arguments
          homeArgs = {
            pkgs = pkgs;
            lib = pkgs.lib;
            inputs = inputs;
            username = "asher";
            # Allow feature overrides via extraArgs
          };
        in
        import ./home.nix homeArgs
      );
    };
}

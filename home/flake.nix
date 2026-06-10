{
  description = "DeMoD - Modular Nix Home Manager Configuration";

  inputs = {
    # Match the system flake's stable pin
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # NOTE: the hyprland flake input was removed — it was never referenced in
    # outputs (the HM module uses pkgs.hyprland) and locked a huge dep tree.
  };

  outputs = { self, nixpkgs, home-manager, ... }:
    let
      lib = nixpkgs.lib;
      systems = [ "x86_64-linux" "aarch64-linux" ];
      forAllSystems = lib.genAttrs systems;
    in
    {
      # ── Standalone use ─────────────────────────────────────────────────────
      #   home-manager switch --flake .#asher
      # Previous version exported raw module imports here, which
      # `home-manager switch` cannot consume. These are real activatable
      # configurations built with homeManagerConfiguration.
      homeConfigurations =
        lib.listToAttrs (map (system: {
          name = if system == "x86_64-linux" then "asher" else "asher-${system}";
          value = home-manager.lib.homeManagerConfiguration {
            pkgs = import nixpkgs {
              inherit system;
              config.allowUnfree = true;
            };
            modules = [ ./home.nix ];
          };
        }) systems);

      # ── NixOS module use ───────────────────────────────────────────────────
      # Host must also import home-manager.nixosModules.home-manager.
      #   programs.demod.enable = true;
      nixosModules.demod = { config, lib, ... }:
        let
          cfg = config.programs.demod;
        in
        {
          options.programs.demod = {
            enable = lib.mkEnableOption "DeMoD home-manager configuration";
            username = lib.mkOption {
              type = lib.types.str;
              default = "asher";
              description = "User to attach the home configuration to.";
            };
          };

          config = lib.mkIf cfg.enable {
            home-manager.users.${cfg.username} = {
              imports = [ ./home.nix ];
            };
          };
        };
    };
}

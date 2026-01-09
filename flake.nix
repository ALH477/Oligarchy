{
  description = "Determinate NixOS Setup for R&D – Framework 16 AMD with CachyOS BORE kernel";

  inputs = {
    # Using unstable for 25.11
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/*";
    nixos-hardware.url = "github:NixOS/nixos-hardware";
    fw-fanctrl.url = "github:TamtamHero/fw-fanctrl/packaging/nix";
    demod-ip-blocker.url = "git+https://github.com/ALH477/DeMoD-IP-Blocker.git";
    minecraft.url = "github:ALH477/NixOS-MineCraft";
    # linux-cachyos input disabled - kernel 6.18.3 build fails with amdgpu
    # Re-enable when CachyOS patches are updated for 6.18 compatibility
    # linux-cachyos = {
    #   url = "github:CachyOS/linux-cachyos";
    #   flake = false;
    # };
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    # Add if using archibaldos-dsp-vm module:
    # archibaldos.url = "github:YOUR_ORG/archibaldos";
  };

  outputs = {
    self,
    nixpkgs,
    nixpkgs-unstable,
    determinate,
    nixos-hardware,
    fw-fanctrl,
    demod-ip-blocker,
    minecraft,
    # linux-cachyos,  # Disabled
    nixos-generators,
    ...
  } @ inputs:

  let
    system = "x86_64-linux";
    # This pkgs instance is used ONLY for the ISO generator
    pkgs = import nixpkgs {
      inherit system;
      config = {
        allowUnfree = true;
        allowBroken = true;
      };
    };
  in {
    # ──────────────────────────────────────────────────────────────
    # Main installed system configuration (nixos-rebuild switch)
    # ──────────────────────────────────────────────────────────────
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = { inherit inputs nixpkgs-unstable; };
      modules = [
        # FIX: Explicitly allow unfree/broken packages for the main system here
        { 
          nixpkgs.config = {
            allowUnfree = true;
            allowBroken = true;
          };
        }
        
        determinate.nixosModules.default
        nixos-hardware.nixosModules.framework-16-7040-amd
        fw-fanctrl.nixosModules.default
        demod-ip-blocker.nixosModules.default
        ./configuration.nix
      ];
    };

    # ──────────────────────────────────────────────────────────────
    # Custom bootable installation ISO
    # ──────────────────────────────────────────────────────────────
    packages = {
      ${system} = {
        iso = (nixos-generators.nixosGenerate {
          inherit pkgs; # Uses the pre-configured pkgs from above
          format = "install-iso";

          specialArgs = { 
            inputs = builtins.removeAttrs inputs [ "self" ]; 
            inherit nixpkgs-unstable; 
          };

          modules = [
            determinate.nixosModules.default
            nixos-hardware.nixosModules.framework-16-7040-amd
            fw-fanctrl.nixosModules.default
            demod-ip-blocker.nixosModules.default
            ./configuration.nix
            
            # Plasma + Calamares installer
            "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-graphical-calamares-plasma6.nix"
            
            {
              # ISO-specific overrides
              services.displayManager.sddm.enable = nixpkgs.lib.mkForce true;
              services.displayManager.sddm.wayland.enable = nixpkgs.lib.mkForce true;
              services.desktopManager.plasma6.enable = nixpkgs.lib.mkForce true;

              boot.supportedFilesystems = pkgs.lib.mkForce [ "btrfs" "reiserfs" "vfat" "f2fs" "xfs" "ntfs" "cifs" ];
              
              users.users.nixos = {
                isNormalUser = true;
                extraGroups = [ "wheel" "networkmanager" "video" "audio" ];
                initialPassword = "nixos";
              };

              services.getty.autologinUser = "nixos";
              services.displayManager.autoLogin = {
                enable = true;
                user = "nixos";
              };

              services.openssh = {
                enable = true;
                settings = {
                  PermitRootLogin = "prohibit-password";
                  PasswordAuthentication = true;
                };
              };

              documentation.enable = false;
              documentation.nixos.enable = false;

              environment.systemPackages = with pkgs; [
                git vim curl wget htop nvme-cli usbutils pciutils
              ];
            }
          ];
        });
        default = self.packages.${system}.iso;
      };
    };
  };
}

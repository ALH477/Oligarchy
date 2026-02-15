{
  description = "Production NixOS – Framework 16 AMD with CachyOS/Zen kernel, DCF Stack, and DSP VM";

  inputs = {
    # Core nixpkgs - using unstable for 25.11
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    
    # Determinate Systems enhancements
    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/*";
    
    # Hardware support
    nixos-hardware.url = "github:NixOS/nixos-hardware";
    
    # Framework fan control
    fw-fanctrl.url = "github:TamtamHero/fw-fanctrl/packaging/nix";
    
    # Custom modules
    demod-ip-blocker.url = "git+https://github.com/ALH477/DeMoD-IP-Blocker.git";
    minecraft.url = "github:ALH477/NixOS-MineCraft";
    
    # OpenClaw AI assistant gateway
    nix-openclaw.url = "github:openclaw/nix-openclaw";
    
    # Home Manager for user-level configuration
    home-manager = {
      url = "github:nix-community/home-manager";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    
    # ISO generation
    nixos-generators = {
      url = "github:nix-community/nixos-generators";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Secrets management
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    
    # ArchibaldOS DSP coprocessor (uncomment when available)
    # archibaldos = {
    #   url = "github:YOUR_ORG/archibaldos";
    #   inputs.nixpkgs.follows = "nixpkgs";
    # };
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
    nix-openclaw,
    home-manager,
    nixos-generators,
    sops-nix,
    # archibaldos,
    ...
  } @ inputs:

  let
    system = "x86_64-linux";
    
    # Shared pkgs configuration
    pkgsConfig = {
      allowUnfree = true;
      allowBroken = true;
      permittedInsecurePackages = [];
    };
    
    # Evaluation pkgs for ISO generation
    pkgs = import nixpkgs {
      inherit system;
      config = pkgsConfig;
    };
    
    # Common specialArgs passed to all modules
    specialArgs = { 
      inherit inputs nixpkgs-unstable; 
      # Uncomment when archibaldos is available:
      # inherit archibaldos;
    };
    
  in {
    # ════════════════════════════════════════════════════════════════════════
    # Main System Configuration
    # ════════════════════════════════════════════════════════════════════════
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      inherit system specialArgs;
      
      modules = [
        # Package configuration
        { nixpkgs.config = pkgsConfig; }
        
        # Third-party modules
        determinate.nixosModules.default
        sops-nix.nixosModules.sops
        nixos-hardware.nixosModules.framework-16-7040-amd
        fw-fanctrl.nixosModules.default
        demod-ip-blocker.nixosModules.default
        
        # Home Manager integration
        home-manager.nixosModules.home-manager
        {
          home-manager = {
            useGlobalPkgs = true;
            useUserPackages = true;
            backupFileExtension = "hm-backup";
            users.asher = import ./home/home.nix;
            extraSpecialArgs = specialArgs;
          };
        }
        
        # Local modules
        ./configuration.nix
        ./modules/hardware-configuration.nix
        ./modules/kernel.nix
        ./modules/agentic-local-ai.nix
        ./modules/openclaw-agent.nix
        ./modules/dcf-community-node.nix
        ./modules/dcf-identity.nix
        ./modules/dcf-tray.nix
        ./modules/secrets.nix
        ./modules/security/strict-egress.nix
        # Uncomment when archibaldos input is available:
        # ./modules/archibaldos-dsp-vm.nix
      ];
    };

    # ════════════════════════════════════════════════════════════════════════
    # Installation ISO & Tests
    # ════════════════════════════════════════════════════════════════════════
    packages.${system} = {
      # ISO installer
      iso = nixos-generators.nixosGenerate {
        inherit pkgs;
        format = "install-iso";
        specialArgs = builtins.removeAttrs specialArgs [ "archibaldos" ];
        
        modules = [
          determinate.nixosModules.default
          nixos-hardware.nixosModules.framework-16-7040-amd
          fw-fanctrl.nixosModules.default
          demod-ip-blocker.nixosModules.default
          ./configuration.nix
          ./modules/hardware-configuration.nix
          ./modules/kernel.nix
          
          "${nixpkgs}/nixos/modules/installer/cd-dvd/installation-cd-graphical-calamares-plasma6.nix"
          
          ({ lib, ... }: {
            # ISO-specific overrides
            services.displayManager.sddm.enable = lib.mkForce true;
            services.displayManager.sddm.wayland.enable = lib.mkForce true;
            services.desktopManager.plasma6.enable = lib.mkForce true;
            
            # Disable production services in ISO
            services.ollamaAgentic.enable = lib.mkForce false;
            custom.dcfCommunityNode.enable = lib.mkForce false;
            custom.dcfIdentity.enable = lib.mkForce false;
            services.dcf-tray.enable = lib.mkForce false;
            networking.firewall.strictEgress.enable = lib.mkForce false;
            
            boot.supportedFilesystems = lib.mkForce [ 
              "btrfs" "reiserfs" "vfat" "f2fs" "xfs" "ntfs" "cifs" 
            ];
            
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
          })
        ];
      };
      
      default = self.packages.${system}.iso;
    };
    
    # ════════════════════════════════════════════════════════════════════════
    # Development Shell with Testing Tools
    # ════════════════════════════════════════════════════════════════════════
    devShells.${system}.default = pkgs.mkShell {
      buildInputs = with pkgs; [
        # Core Nix development
        nil  # Nix LSP
        nixpkgs-fmt
        nix-tree
        nvd  # NixOS version diff
        
        # Testing tools
        testers  # NixOS test framework
        qemu  # Full QEMU (for manual VM testing)
        virt-manager  # GUI for VM management
        libvirt  # Virtualization library
        virt-viewer  # Minimal SPICE client
        
        # TUI tools for testing
        nix-tree  # Explore Nix store
        nix-diff  # Compare Nix derivations
        nix-show-derivation  # View derivation info
        nix-visualize-derivation  # Visualize derivation graph
        
        # Network testing
        nmap  # Network scanner
        iperf3  # Network bandwidth tester
        tcpdump  # Packet analyzer
        wiresharkCLI  # CLI Wireshark
        
        # Debugging
        gdb  # Debugger
        strace  # System call tracer
        ltrace  # Library call tracer
        lsof  # List open files
        netstat-nat  # NAT connections
        
        # System analysis
        htop  # Process viewer
        iftop  # Network traffic monitor
        iotop  # I/O monitor
        atop  # Advanced system monitor
      ];
      
      shellHook = ''
        echo "╔═══════════════════════════════════════════════════════════════╗"
        echo "║         Oligarchy NixOS Development Shell                    ║"
        echo "╠═══════════════════════════════════════════════════════════════╣"
        echo "║ Testing Commands:                                              ║"
        echo "║   nix flake check          - Run all automated tests          ║"
        echo "║   nix run .#test          - Run specific test (see below)    ║"
        echo "║   nix build .#oligarchy-boot - Build boot test VM              ║"
        echo "║   nix build .#strict-egress - Build strict-egress test        ║"
        echo "║                                                                ║"
        echo "║ Available Tests:                                               ║"
        echo "║   oligarchy-boot    - Basic boot + connectivity test          ║"
        echo "║   strict-egress    - Firewall module test                     ║"
        echo "║   config-eval     - Configuration evaluation test            ║"
        echo "║                                                                ║"
        echo "║ TUI Tools:                                                     ║"
        echo "║   tui哥伦          - Terminal UI for Nix                      ║"
        echo "║   nix-tree        - Explore Nix store                        ║"
        echo "║   htop            - Process monitor                          ║"
        echo "║   iftop           - Network monitor                          ║"
        echo "╚═══════════════════════════════════════════════════════════════╝"
      '';
    };
  };
}

{
  description = "Production NixOS – Framework 16 AMD with CachyOS/Zen kernel, DCF Stack, and DSP VM";

  inputs = {
    # Core nixpkgs — pinned to the current stable release (25.11).
    # nixpkgs-unstable stays available for cherry-picks via the `unstable` overlay.
    # Revert knob: point nixpkgs back at nixos-unstable if a package you need
    # hasn't landed in 25.11 and you don't want to use the overlay.
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";
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

    # Secure Boot (opt-in via custom.secureBoot.enable). Tracks the default
    # branch for reliable locking; pin a release tag if you prefer.
    lanzaboote = {
      url = "github:nix-community/lanzaboote";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # Home Manager for user-level configuration — pinned to the release branch
    # matching nixpkgs. HM master tracks unstable and will drift from 25.11.
    home-manager = {
      url = "github:nix-community/home-manager/release-25.11";
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

    # Oligarchy Greeting - War Room TUI
    greeting.url = "path:./modules/greeting";

    # DeMoD Boot Intro Suite
    boot-intro.url = "path:./modules/boot-intro";

    # Blipply Assistant - AI Voice Assistant (as flake input)
    blipply-assistant.url = "path:./modules/blipply-assistant";

    # ArchibaldOS DSP coprocessor (uncomment when available)
    # archibaldos = {
    #   url = "github:YOUR_ORG/archibaldos";
    #   inputs.nixpkgs.follows = "nixpkgs";
    # };

    # VM Manager - Hybrid VM management
    vm-manager.url = "path:./vm-manager";

    # DeMoD Voice - Local TTS and Voice Cloning
    demod-voice.url = "path:./modules/demod-voice";

    # DeMoD Communication Framework mesh (agent-to-agent)
    hydra-mesh = {
      url = "github:ALH477/HydraMesh";
      flake = false;   # we only consume files from it, no flake outputs needed
    };
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
    greeting,
    boot-intro,
    blipply-assistant,
    home-manager,
    nixos-generators,
    sops-nix,
    vm-manager,
    demod-voice,
    # archibaldos,
    ...
  } @ inputs:

  let
    system = "x86_64-linux";

    # Shared pkgs configuration
    # allowBroken removed: it silently lets known-broken packages into the
    # closure on a production machine. Override per-package if ever needed.
    pkgsConfig = {
      allowUnfree = true;
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
      inherit vm-manager;
    };

    # ════════════════════════════════════════════════════════════════════════
    # Shared module set — single source of truth for system AND ISO.
    # configuration.nix sets services.ollamaAgentic and the ISO overrides
    # networking.firewall.strictEgress; the modules that
    # DECLARE those options must therefore be present in every evaluation that
    # includes configuration.nix, or eval fails with "option does not exist".
    # Previously the ISO list omitted them — that's why the ISO didn't build.
    # ════════════════════════════════════════════════════════════════════════
    commonModules = [
      # Package configuration
      { nixpkgs.config = pkgsConfig; }

      # Third-party modules (board-specific hardware modules live per-host below)
      determinate.nixosModules.default
      sops-nix.nixosModules.sops
      demod-ip-blocker.nixosModules.default

      # Hardware platform abstraction (custom.platform.{gpu,cpu,framework,...}).
      # Per-host modules set the gpu/cpu; default is the Framework 16 AMD config.
      ./modules/platform.nix

      # Local modules - order matters! Options must be defined before config uses them
      # Boot intro options (single module; TUI/API/StreamDB stubs were removed)
      boot-intro.nixosModules.boot-intro

      # Blipply integration (defines oligarchy.blipply options)
      ./modules/blipply-integration.nix

      # Main configuration (uses options defined above).
      # Note: configuration.nix itself imports modules/audio.nix and the three
      # dcf-*.nix modules, so those travel with it. hardware-configuration.nix
      # and the nixos-hardware board module are per-host (see below).
      ./configuration.nix
      ./modules/kernel.nix
      ./modules/personas.nix
      ./modules/dsp-rigs.nix
      ./modules/secure-boot.nix
      ./modules/agentic-local-ai.nix
      ./modules/oligarchy-mcp.nix
      ./modules/secrets.nix
      ./modules/security/strict-egress.nix
      greeting.nixosModules.greeting

      # Blipply Assistant - AI Voice Assistant (integrated from local source)
      blipply-assistant.nixosModules.default

      # VM Manager - Hybrid VM management
      vm-manager.nixosModules.quickemu-vm
      vm-manager.nixosModules.dsp-vm

      # DeMoD Voice - Local TTS and Voice Cloning
      ./modules/demod-voice/nixos-module.nix

      # Uncomment when archibaldos input is available:
      # ./modules/archibaldos-dsp-vm.nix
    ];

    # Home Manager integration (system only — the ISO's live user is created by
    # the installer profile, not by HM). Shared by every host.
    hmModule = {
      imports = [ home-manager.nixosModules.home-manager ];
      home-manager = {
        useGlobalPkgs = true;
        useUserPackages = true;
        backupFileExtension = "hm-backup";
        users.asher = import ./home/home.nix;
        extraSpecialArgs = specialArgs;
      };
    };

    mkHost = hostModules: nixpkgs.lib.nixosSystem {
      inherit system specialArgs;
      modules = commonModules ++ [ hmModule ] ++ hostModules;
    };

  in {
    # ════════════════════════════════════════════════════════════════════════
    # System Configurations (one per hardware target)
    # ════════════════════════════════════════════════════════════════════════

    # Framework 16 AMD 7040 — the original target, behaviour unchanged.
    nixosConfigurations.nixos = mkHost [
      nixos-hardware.nixosModules.framework-16-7040-amd
      fw-fanctrl.nixosModules.default
      ./modules/hardware-configuration.nix
      { custom.platform = { gpu = "amd"; cpu = "amd"; framework = true; }; }
    ];

    # Pure Intel laptop (iGPU only, CPU inference).
    nixosConfigurations.nixos-intel = mkHost [
      nixos-hardware.nixosModules.common-cpu-intel
      nixos-hardware.nixosModules.common-gpu-intel
      nixos-hardware.nixosModules.common-pc-laptop-ssd
      ./hosts/intel/hardware-configuration.nix
      { custom.platform = { gpu = "intel"; cpu = "intel"; framework = false; }; }
    ];

    # Intel + Nvidia Optimus laptop (PRIME render offload, CUDA AI stack).
    # Fill in the PCI bus ids in hosts/optimus/hardware-configuration.nix or here.
    nixosConfigurations.nixos-optimus = mkHost [
      nixos-hardware.nixosModules.common-cpu-intel
      nixos-hardware.nixosModules.common-gpu-intel   # iGPU (primary display under offload)
      nixos-hardware.nixosModules.common-gpu-nvidia  # = prime.nix (offload)
      nixos-hardware.nixosModules.common-pc-laptop-ssd
      ./hosts/optimus/hardware-configuration.nix
      {
        custom.platform = {
          gpu = "nvidia-optimus";
          cpu = "intel";
          framework = false;
          # Obtain with: lspci | grep -E 'VGA|3D|Display'  ("01:00.0" -> "PCI:1:0:0")
          nvidia.intelBusId = "PCI:0:2:0";
          nvidia.nvidiaBusId = "PCI:1:0:0";
        };
      }
    ];

    # ════════════════════════════════════════════════════════════════════════
    # Installation ISO & Tests
    # ════════════════════════════════════════════════════════════════════════
    packages.${system} = {
      # ISO installer
      # Pass `system`, NOT `pkgs`: handing nixosGenerate an externally-built
      # pkgs sets nixpkgs.pkgs, which collides with the `{ nixpkgs.config = … }`
      # module in commonModules and trips the "externally created instance"
      # assertion (nixpkgs lib/eval-config.nix only sets nixpkgs.pkgs when
      # pkgs != null). With `system`, nixpkgs is built internally and honours
      # nixpkgs.config.
      iso = nixos-generators.nixosGenerate {
        inherit system;
        format = "install-iso";
        specialArgs = builtins.removeAttrs specialArgs [ "archibaldos" ];

        modules = commonModules ++ [
          # Installer image targets the Framework 16 AMD (status quo). Hardware
          # modules are now per-host, so re-add them explicitly here.
          nixos-hardware.nixosModules.framework-16-7040-amd
          fw-fanctrl.nixosModules.default
          ./modules/hardware-configuration.nix
          { custom.platform = { gpu = "amd"; cpu = "amd"; framework = true; }; }

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
    # Checks & Formatter
    # `nix flake check` now evaluates AND builds the full system closure —
    # the same artifact nixos-rebuild would produce. Heavy but honest.
    # For a fast eval-only smoke test use:
    #   nixos-rebuild dry-build --flake .#nixos
    # ════════════════════════════════════════════════════════════════════════
    checks.${system} = {
      system = self.nixosConfigurations.nixos.config.system.build.toplevel;
    };

    formatter.${system} = pkgs.nixfmt-rfc-style;

    # ════════════════════════════════════════════════════════════════════════
    # Development Shell with Testing Tools
    # ════════════════════════════════════════════════════════════════════════
    devShells.${system}.default = pkgs.mkShell {
      buildInputs = with pkgs; [
        # Core Nix development
        nil  # Nix LSP
        nixpkgs-fmt
        nixfmt-rfc-style
        nix-tree  # Explore Nix store
        nix-diff  # Compare Nix derivations
        nvd  # NixOS version diff

        # VM / virtualization tools
        qemu  # Full QEMU (for manual VM testing)
        virt-manager  # GUI for VM management
        libvirt  # Virtualization library
        virt-viewer  # Minimal SPICE client

        # Network testing
        nmap  # Network scanner
        iperf3  # Network bandwidth tester
        tcpdump  # Packet analyzer
        wireshark-cli  # CLI Wireshark (tshark)

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
        echo "╔════════════════════════════════════════════════════════════════╗"
        echo "║              Oligarchy NixOS Development Shell                 ║"
        echo "╠════════════════════════════════════════════════════════════════╣"
        echo "║ Commands:                                                      ║"
        echo "║   nix flake check                  - eval + build system       ║"
        echo "║   nixos-rebuild dry-build \\                                    ║"
        echo "║     --flake .#nixos                - fast eval smoke test      ║"
        echo "║   nix build .#iso                  - build installer ISO       ║"
        echo "║   nix fmt                          - format Nix sources        ║"
        echo "║   nvd diff /run/current-system ./result - diff closures        ║"
        echo "║                                                                ║"
        echo "║ Tools: nix-tree, nix-diff, htop, iftop, tshark, qemu           ║"
        echo "╚════════════════════════════════════════════════════════════════╝"
      '';
    };
  };
}

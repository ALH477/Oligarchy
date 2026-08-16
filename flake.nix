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

    # Custom modules
    demod-ip-blocker.url = "git+https://github.com/ALH477/DeMoD-IP-Blocker.git";
    minecraft.url = "path:./modules/minecraft";

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

    # Dedicated MCP servers — one Rust process per OS aspect + the
    # `ports-sec` auditor. See `docs/mcp-servers-roadmap.md`. Replaces the
    # legacy monolithic Python `oligarchy-mcp` server.
    mcp-servers.url = "path:./modules/mcp-servers";

    # DSP Coprocessor Control — TUI/CLI for ArchibaldOS DSP VM
    dsp-ctl.url = "path:./modules/dsp-ctl";

    # oligarchy-forge — sandboxed coding-agent runner (TOML schema ->
    # generated flake.nix -> nix build -> podman/docker run). See
    # docs/oligarchy-forge-roadmap.md for the full design + living roadmap.
    oligarchy-forge.url = "path:./modules/oligarchy-forge";

    # DeMoD Voice - Local TTS and Voice Cloning
    demod-voice.url = "path:./modules/demod-voice";

    # DeMoD Communication Framework / HydraMesh — the mesh protocol, codec and
    # modem stack the DCF services are built on. A HARD REQUIREMENT of the
    # distro (see ./modules/hydramesh.nix), not an optional add-on: it supplies
    # the `hydramesh`, `dcf` and hydramodem CLIs that the `hydramesh` MCP aspect
    # shells out to.
    #
    # Consumed as a real flake (packages + apps). Deliberately NOT `follows`-ing
    # our nixpkgs: HydraMesh pins nixpkgs-faust to nixos-24.05 for the Faust
    # 2.72.14 ABI and tracks nixos-unstable for the rest, while we are on
    # nixos-25.11. Forcing a follow breaks its Faust/SBCL builds.
    hydramesh.url = "github:ALH477/HydraMesh";

    # Community YARA ruleset — pinned so the Malware Shield build gate
    # (packages.malwareScan) scans the closure with deterministic, offline
    # rules. We consume .yar files only, no flake outputs.
    yara-rules = {
      url = "github:Yara-Rules/rules";
      flake = false;
    };
  };

  outputs =
    { self
    , nixpkgs
    , nixpkgs-unstable
    , determinate
    , nixos-hardware
    , demod-ip-blocker
    , minecraft
    , greeting
    , boot-intro
    , blipply-assistant
    , home-manager
    , nixos-generators
    , sops-nix
    , vm-manager
    , dsp-ctl
    , oligarchy-forge
    , demod-voice
    , mcp-servers
    , hydramesh
    , yara-rules
    , # archibaldos,
      ...
    } @ inputs:

    let
      system = "x86_64-linux";

      # Shared pkgs configuration
      # allowBroken removed: it silently lets known-broken packages into the
      # closure on a production machine. Override per-package if ever needed.
      pkgsConfig = {
        allowUnfree = true;
        permittedInsecurePackages = [ ];
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
        inherit vm-manager dsp-ctl oligarchy-forge mcp-servers hydramesh;
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

        # Primary-account identity (custom.user.name / .sshAuthorizedKeys).
        # Declared before configuration.nix and the modules that consume it.
        ./modules/user.nix

        # Local modules - order matters! Options must be defined before config uses them
        # Boot intro options (single module; TUI/API/StreamDB stubs were removed)
        boot-intro.nixosModules.boot-intro

        # Blipply integration (defines oligarchy.blipply options)
        ./modules/blipply-integration.nix

        # Dedicated MCP servers (custom.mcpServers.*) — replaces the legacy
        # ./modules/oligarchy-mcp.nix. Order is important: the options stay
        # alphabetically grouped with the other local modules.
        mcp-servers.nixosModules.default

        # HydraMesh / DCF SDK CLIs (custom.hydramesh.*). Declared before
        # configuration.nix like the other option-providing local modules.
        # Unlike most custom.* features this one defaults to ON — HydraMesh is a
        # requirement of the distro, not an opt-in.
        ./modules/hydramesh.nix

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
        # oligarchy-mcp.nix removed — replaced by mcp-servers.nixosModules.default
        ./modules/secrets.nix
        ./modules/security/strict-egress.nix
        ./modules/security/dcf-spa-gate.nix
        ./modules/security/hardening.nix
        ./modules/security/malware-shield.nix
        ./modules/security/security-cli.nix
        ./modules/cpu-security.nix
        greeting.nixosModules.greeting

        # Blipply Assistant - AI Voice Assistant (integrated from local source)
        blipply-assistant.nixosModules.default

        # VM Manager - Hybrid VM management
        vm-manager.nixosModules.quickemu-vm
        vm-manager.nixosModules.dsp-vm

        # DSP Coprocessor Control — TUI/CLI tool
        dsp-ctl.nixosModules.dsp-ctl

        # oligarchy-forge — sandboxed coding-agent runner (custom.oligarchyForge.*)
        oligarchy-forge.nixosModules.default

        # DeMoD Voice - Local TTS and Voice Cloning
        ./modules/demod-voice/nixos-module.nix

        # Uncomment when archibaldos input is available:
        # ./modules/archibaldos-dsp-vm.nix
      ];

      # Home Manager integration (system only — the ISO's live user is created by
      # the installer profile, not by HM). Shared by every host.
      hmModule = { config, ... }: {
        imports = [ home-manager.nixosModules.home-manager ];
        home-manager = {
          useGlobalPkgs = true;
          useUserPackages = true;
          backupFileExtension = "hm-backup";
          users.${config.custom.user.name} = import ./home/home.nix;
          extraSpecialArgs = specialArgs // { primaryUsername = config.custom.user.name; };
        };
      };

      mkHost = hostModules: nixpkgs.lib.nixosSystem {
        inherit system specialArgs;
        modules = commonModules ++ [ hmModule ] ++ hostModules;
      };

      # Installer-only helper: detects Framework 13 vs 16 (or neither) via DMI,
      # suggests the matching `nixosConfigurations.*` target, walks through
      # `nixos-generate-config` for the real disk UUIDs, and offers to check/
      # apply pending Framework BIOS/EC firmware updates via fwupd/LVFS before
      # install. Read-only aside from the opt-in `fwupdmgr update` step; never
      # runs automatically. See README.md's "Pick Your War Machine" section.
      oligarchyHwDetect = pkgs.writeShellScriptBin "oligarchy-hw-detect" ''
        set -euo pipefail

        echo "== Oligarchy hardware + firmware check =="
        echo

        product=$(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)
        vendor=$(cat /sys/class/dmi/id/sys_vendor 2>/dev/null || echo unknown)
        echo "DMI vendor/product: $vendor / $product"

        case "$product" in
          *"Laptop 13"*) target="nixos-fw13 (Framework 13 AMD)" ;;
          *"Laptop 16"*) target="nixos (Framework 16 AMD)" ;;
          *) target="nixos-intel or nixos-optimus (non-Framework — nixos-optimus if you have Intel+Nvidia, nixos-intel otherwise)" ;;
        esac
        echo "Suggested flake target: $target"
        echo
        echo "Next steps:"
        echo "  1. Partition + mount your disks under /mnt as usual."
        echo "  2. nixos-generate-config --root /mnt --show-hardware-config > /tmp/hw.nix"
        echo "  3. Copy the filesystems section of /tmp/hw.nix into the matching"
        echo "     hosts/<target>/hardware-configuration.nix, replacing the"
        echo "     FILL-IN-*-UUID markers (or modules/hardware-configuration.nix"
        echo "     for the nixos/Framework-16 target)."
        echo "  4. sudo nixos-install --flake <path-to-flake>#<target>"
        echo

        if command -v fwupdmgr >/dev/null 2>&1; then
          echo "== Firmware (BIOS/EC) check via fwupd/LVFS =="
          fwupdmgr get-devices || true
          echo
          if fwupdmgr get-updates 2>/dev/null; then
            echo
            read -r -p "Apply pending firmware updates now, before installing? [y/N] " ans
            case "$ans" in
              y|Y) fwupdmgr update ;;
              *) echo "Skipping — run 'fwupdmgr update' later from the installed system." ;;
            esac
          else
            echo "No pending updates, or fwupd couldn't reach LVFS (offline install?)."
          fi
        else
          echo "fwupdmgr not present on this image."
        fi
      '';
    in
    {
      # ════════════════════════════════════════════════════════════════════════
      # System Configurations (one per hardware target)
      # ════════════════════════════════════════════════════════════════════════

      # Framework 16 AMD 7040 — the original target, behaviour unchanged.
      nixosConfigurations.nixos = mkHost [
        nixos-hardware.nixosModules.framework-16-7040-amd
        ./modules/hardware-configuration.nix
        { custom.platform = { gpu = "amd"; cpu = "amd"; framework = true; }; }
      ];

      # Framework 13 AMD 7040 — iGPU only, no expansion-bay dGPU. Unverified
      # against real hardware (see hosts/framework13/hardware-configuration.nix).
      nixosConfigurations.nixos-fw13 = mkHost [
        nixos-hardware.nixosModules.framework-13-7040-amd
        ./hosts/framework13/hardware-configuration.nix
        {
          custom.platform = {
            gpu = "amd";
            cpu = "amd";
            framework = true;
            frameworkModel = "13";
            hasDgpu = false;
          };
        }
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
        nixos-hardware.nixosModules.common-gpu-intel # iGPU (primary display under offload)
        nixos-hardware.nixosModules.common-gpu-nvidia # = prime.nix (offload)
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
              hardware.cpuSecurity.enable = lib.mkForce false;
              custom.security.hardening.enable = lib.mkForce false;
              custom.malwareShield.enable = lib.mkForce false;
              custom.secrets.enable = lib.mkForce false;
              custom.mcpServers.enable = lib.mkForce false;
              custom.oligarchyForge.enable = lib.mkForce false;
              # HydraMesh is a requirement of the INSTALLED system, but its SBCL
              # (hydramesh-lisp) and Faust/GCC (hydramodem) builds have no place in
              # the installer image. Drop this mkForce if the ISO must ship them.
              custom.hydramesh.enable = lib.mkForce false;

              boot.supportedFilesystems = lib.mkForce [
                "btrfs"
                "reiserfs"
                "vfat"
                "f2fs"
                "xfs"
                "ntfs"
                "cifs"
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

              # Framework hardware-detect + fwupd firmware-check helper —
              # run `oligarchy-hw-detect` from a TTY before nixos-install.
              environment.systemPackages = [ oligarchyHwDetect ];
              services.fwupd.enable = lib.mkForce true;
            })
          ];
        };

        default = self.packages.${system}.iso;

        # Standalone package too, so it can be pulled into a dev shell or run
        # directly on an already-installed system for a firmware check:
        #   nix run .#oligarchy-hw-detect
        oligarchy-hw-detect = oligarchyHwDetect;

        # ════════════════════════════════════════════════════════════════════
        # MCP self-audit build gate — runs the ports-sec `mcp_self_audit`
        # tool from the sub-flake against the sub-flake's own source tree. It
        # fails the build if any forbidden pattern (TcpListener, reqwest
        # outside ports-sec, etc.) is found in the workspace, or if .mcp.json
        # contains a URL/HTTP transport entry. Mirrors the `malwareScan`
        # precedent. Run on demand:  nix build .#mcp-self-audit
        #
        # Defined here rather than re-exported from the sub-flake because only
        # this flake can see the repo-root `.mcp.json`. The sub-flake's own
        # `mcpSelfAudit` runs the same source scan but reports the .mcp.json leg
        # as SKIPPED, since standalone it has no repo root above it.
        # ════════════════════════════════════════════════════════════════════
        mcp-self-audit = pkgs.runCommand "oligarchy-mcp-self-audit"
          {
            nativeBuildInputs = [ mcp-servers.packages.${system}."oligarchy-ports-sec-mcp" ];
            meta = with nixpkgs.lib; {
              description = "MCP self-audit build gate — forbidden socket patterns + .mcp.json transports";
              license = licenses.mit;
              platforms = platforms.linux;
            };
          }
          ''
            mkdir -p $out
            export OLIGARCHY_MCP_WORKSPACE=${./modules/mcp-servers}
            export OLIGARCHY_MCP_JSON=${./.mcp.json}
            oligarchy-ports-sec-mcp --self-audit > $out/report.txt 2>&1 || {
              echo "mcp-self-audit FAILED — see $out/report.txt" >&2
              cat $out/report.txt
              exit 1
            }
            cat $out/report.txt
          '';

        # ════════════════════════════════════════════════════════════════════
        # Malware Shield build gate — scans the FULL system closure with pinned,
        # offline YARA rules (vendored starters + the yara-rules input). Fails
        # the build if a signature hits. Deliberately NOT in `checks` (a
        # closure-sized YARA sweep is slow on this machine and `nix flake check`
        # already builds the toplevel). Run on demand:  nix build .#malwareScan
        # ════════════════════════════════════════════════════════════════════
        malwareScan =
          let
            toplevel = self.nixosConfigurations.nixos.config.system.build.toplevel;
          in
          pkgs.runCommand "oligarchy-malware-scan"
            {
              nativeBuildInputs = [ pkgs.yara ];
              # Realize the whole runtime closure so YARA sees every store path.
              exportReferencesGraph = [ "closure" toplevel ];
            }
            ''
              echo "Scanning system closure with pinned YARA rules..."
              rules="${./modules/security/yara-rules}"
              hits=0
              # Vendored rules over every path in the closure. The upstream
              # yara-rules tree contains rules with external-variable deps that
              # won't compile standalone, so the gate uses the vendored set that
              # is guaranteed to compile; extend deliberately from the pinned
              # yara-rules input (${yara-rules}).
              for rulefile in "$rules"/*.yar; do
                while IFS= read -r path; do
                  [ -e "$path" ] || continue
                  if yara -w -r "$rulefile" "$path" 2>/dev/null | grep -q .; then
                    echo "MALWARE SIGNATURE MATCH: $rulefile in $path"
                    hits=$((hits+1))
                  fi
                done < <(grep '^/nix/store' closure | sort -u)
              done
              if [ "$hits" -gt 0 ]; then
                echo "Build gate FAILED: $hits signature match(es) in the closure." >&2
                exit 1
              fi
              echo "Clean: no signatures in the system closure."
              touch $out
            '';
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
      # BIOS UMA/iGPU-carve-out unlock tooling — deliberately isolated from
      # devShells.default and from every nixosConfiguration. Entered by hand
      # only: `nix develop .#bios-tools`. See docs/bios-uma-unlock.md — this
      # is real firmware modification with real bricking risk; nothing here
      # runs automatically or is part of any build/boot path.
      # ════════════════════════════════════════════════════════════════════════
      devShells.${system} = {
      bios-tools = pkgs.mkShell {
        buildInputs = [
          pkgs.flashrom
          pkgs.uefitool
          pkgs.chipsec
          pkgs.ifrextractor-rs

          (pkgs.writeShellScriptBin "oligarchy-bios-uma-unlock" ''
            set -euo pipefail

            usage() {
              echo "Usage:"
              echo "  oligarchy-bios-uma-unlock read  <VarName> <VarGuid>"
              echo "  oligarchy-bios-uma-unlock write <VarName> <VarGuid> <offset> <hex-byte> --backup <path>"
              echo
              echo "Read docs/bios-uma-unlock.md in full before using 'write'."
              exit 1
            }

            [ $# -ge 1 ] || usage
            cmd="$1"; shift

            case "$cmd" in
              read)
                [ $# -eq 2 ] || usage
                name="$1"; guid="$2"
                tmp=$(mktemp)
                echo "+ chipsec_util uefi var-read '$name' '$guid' '$tmp'"
                sudo chipsec_util uefi var-read "$name" "$guid" "$tmp"
                echo "== hex dump =="
                xxd "$tmp"
                rm -f "$tmp"
                ;;
              write)
                [ $# -eq 6 ] && [ "$5" = "--backup" ] || usage
                name="$1" guid="$2" offset="$3" newbyte="$4" backup="$6"

                [ -s "$backup" ] || { echo "Backup file '$backup' missing or empty — refusing to continue." >&2; exit 1; }

                echo "This will modify a live UEFI Setup NVRAM variable on this machine."
                echo "Variable: $name  GUID: $guid  offset: $offset  new byte: $newbyte"
                echo "Confirmed backup present at: $backup"
                echo
                echo "Have you (a) read docs/bios-uma-unlock.md in full, (b) independently"
                echo "identified this exact offset from YOUR OWN BIOS dump via IFRExtractor"
                echo "(not a guess), and (c) got the machine on AC power with no other"
                echo "critical work in progress?"
                echo
                read -r -p "Type exactly: I ACCEPT THE BRICK RISK   " confirm
                [ "$confirm" = "I ACCEPT THE BRICK RISK" ] || { echo "Aborted."; exit 1; }

                cur=$(mktemp); new=$(mktemp)
                sudo chipsec_util uefi var-read "$name" "$guid" "$cur"
                echo "== current value =="; xxd "$cur"

                cp "$cur" "$new"
                printf "$(printf '\\x%s' "$newbyte")" | dd of="$new" bs=1 seek="$offset" count=1 conv=notrunc status=none

                echo "== proposed new value =="; xxd "$new"
                read -r -p "Write this? [y/N] " go
                [ "$go" = "y" ] || [ "$go" = "Y" ] || { echo "Aborted, nothing written."; rm -f "$cur" "$new"; exit 1; }

                sudo chipsec_util uefi var-write "$name" "$guid" "$new"

                verify=$(mktemp)
                sudo chipsec_util uefi var-read "$name" "$guid" "$verify"
                echo "== read-back after write =="; xxd "$verify"
                cmp -s "$new" "$verify" && echo "Verified: variable now matches what was written." \
                  || echo "WARNING: read-back does not match what was written — investigate before rebooting."
                rm -f "$cur" "$new" "$verify"
                ;;
              *) usage ;;
            esac
          '')
        ];

        shellHook = ''
          echo "bios-tools shell — read docs/bios-uma-unlock.md before doing anything."
          echo "This shell can modify live firmware NVRAM. Nothing here runs unless you run it."
        '';
      };

      # ════════════════════════════════════════════════════════════════════════
      # Development Shell with Testing Tools
      # ════════════════════════════════════════════════════════════════════════
      default = pkgs.mkShell {
        buildInputs = with pkgs; [
          # Core Nix development
          nil # Nix LSP
          nixpkgs-fmt
          nixfmt-rfc-style
          nix-tree # Explore Nix store
          nix-diff # Compare Nix derivations
          nvd # NixOS version diff

          # VM / virtualization tools
          qemu # Full QEMU (for manual VM testing)
          virt-manager # GUI for VM management
          libvirt # Virtualization library
          virt-viewer # Minimal SPICE client

          # Network testing
          nmap # Network scanner
          iperf3 # Network bandwidth tester
          tcpdump # Packet analyzer
          wireshark-cli # CLI Wireshark (tshark)

          # Debugging
          gdb # Debugger
          strace # System call tracer
          ltrace # Library call tracer
          lsof # List open files
          # netstat-nat removed (no longer in nixpkgs)

          # System analysis
          htop # Process viewer
          iftop # Network traffic monitor
          iotop # I/O monitor
          atop # Advanced system monitor
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
          echo "║   nix build .#malwareScan          - YARA-scan the closure     ║"
          echo "║   nix fmt                          - format Nix sources        ║"
          echo "║   nvd diff /run/current-system ./result - diff closures        ║"
          echo "║   oligarchy-security status        - live security posture     ║"
          echo "║                                                                ║"
          echo "║ Tools: nix-tree, nix-diff, htop, iftop, tshark, qemu           ║"
          echo "╚════════════════════════════════════════════════════════════════╝"
        '';
      };
      };
    };
}

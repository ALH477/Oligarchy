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

    # oligarchy-plugins — the tiered sandboxed plugin runtime (custom.plugins.*)
    # and the foundation the FX Bazaar is meant to sit on: one WIT ABI across
    # three tiers, with W^X decided per plugin instead of per machine. STAGED —
    # only tier 0 is wired, on the workstation host below. Staging plan and
    # per-stage gates: docs/plugins-roadmap.md.
    #
    # A *read-write* runtime, same category as oligarchy-forge and dsp-ctl, so
    # like them it must stay out of the read-only MCP surface (.#mcp-self-audit
    # fails the build if it lands in .mcp.json).
    oligarchy-plugins = {
      url = "path:./modules/oligarchy-plugins";
      inputs.nixpkgs.follows = "nixpkgs";
      # Only the sub-flake's devShell uses rust-overlay, and nothing here
      # evaluates that; following an existing pin keeps it out of the lock's
      # fetch set rather than adding a sixth distinct rust-overlay rev.
      inputs.rust-overlay.follows = "mcp-servers/rust-overlay";
    };

    # oligarchy-p2p — the P2P substituter: a loopback Nix binary-cache adapter
    # that lets Nix obtain NARs over a peer transport without Nix being patched
    # and without weakening its trust model. STAGED — stage 1 is a verifying
    # pass-through proxy with no transport yet, wired on the workstation host
    # below and DISABLED by default there. Staging plan, gates and the measured
    # facts the design rests on: docs/p2p-substituter-roadmap.md.
    #
    # Read-write and network-facing, same category as oligarchy-forge and
    # oligarchy-plugins, so like them it must stay out of the read-only MCP
    # surface (.#mcp-self-audit fails the build if it lands in .mcp.json).
    oligarchy-p2p = {
      url = "path:./modules/oligarchy-p2p";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # DCF-Talk — decentralized voice + text over the 17-byte DeModFrame.
    # Off by default (services.demod-talk.enable); see modules/demod-talk/README.md.
    # Plaintext by design, so the module REQUIRES a WireGuard interface.
    demod-talk.url = "path:./modules/demod-talk";

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
    , demod-talk
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
    , oligarchy-plugins
    , oligarchy-p2p
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
        inherit demod-talk;
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
        demod-talk.nixosModules.demod-talk

        # Hardware platform abstraction (custom.platform.{gpu,cpu,framework,...}).
        # Per-host modules set the gpu/cpu; default is the Framework 16 AMD config.
        ./modules/platform.nix

        # Primary-account identity (custom.user.name / .sshAuthorizedKeys).
        # Declared before configuration.nix and the modules that consume it.
        ./modules/user.nix

        # custom.desktopFeatures.* — makes home/home.nix's feature set
        # (enableDev/enableGaming/enableAudio/enableDCF/enableScratchpads/
        # enablePersonalApps) a real, overridable option instead of a
        # hardcoded home-manager let-binding. Declared before configuration.nix
        # and home/home.nix, both of which consume it.
        ./modules/desktop-features.nix

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
        ./modules/security/ip-blocklists.nix
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

        # Tiered plugin runtime — STAGE 1 (tier 0 only), and this is the only
        # host that gets it. The other three and the ISO are untouched;
        # `custom.plugins.enable` defaults to false, so nothing to force off.
        #
        # These settings are the shipped-instrument posture, not a development
        # relaxation, and a stage rig keeps them permanently. allowedTiers is
        # not merely a runtime refusal either: the module derives the plugind
        # package from it, so on a wasm-only host libloading, mlua and the
        # vendored LuaJIT are not in the closure at all. requireSignature with
        # no keys yet means nothing can be registered — which is the intent
        # here: the runtime is present, the registry is shut.
        #
        # Staging plan, per-stage gates and known gaps: docs/plugins-roadmap.md
        # nixosModules.default rather than .plugins: it adds microvm.nix's host
        # module, which tier 2 needs and which the other three hosts have no use
        # for. custom.plugins asserts on the difference rather than silently
        # doing nothing if you get it wrong.
        oligarchy-plugins.nixosModules.default
        ({ config, ... }: {
          custom.plugins = {
            enable = true;

            # Stage 3: tier 1. Native and Lua plugins run under bwrap +
            # Landlock + seccomp, which is what makes CLAP/LV2/Faust-native DSP
            # possible on a sub-millisecond guitar path where the Wasm boundary
            # is measurable. This is the WORKSTATION only — a stage rig or a
            # shipped instrument keeps [ "wasm" ] and allowSelfJit = false,
            # because there it is running plugins somebody else wrote.
            allowedTiers = [ "wasm" "native" "lua" "microvm" ];

            # The concession, and it is a real one: a plugin declaring
            # jit = "self" runs with MemoryDenyWriteExecute=no. It emits a build
            # warning on purpose. Verified on this hardware rather than assumed
            # — `plugind selftest` reports mprotect(PROT_EXEC) and memfd_create
            # DENIED for jit=none and allowed for jit=self on the zen kernel.
            #
            # Two things keep it bounded. Manifest validation refuses
            # untrusted + jit=self outside tier 2 outright, and a request that
            # arrived over the control socket cannot ask for it at all
            # (Authority::Socket) — whether a signed plugin may hold W+X pages
            # is the operator's call, not something install-group membership
            # buys.
            allowSelfJit = true;

            # Tightened now that native code can load: refuse a manifest that
            # only claims "untrusted". Read it as a filter on a claim rather
            # than a boundary — see the option docs — but combined with
            # requireSignature it means an author put their name to it.
            minTrust = "trusted";

            # Stage 4: tier 2. A microVM guest is the only honest place for a
            # plugin that is BOTH untrusted and ships its own code generator —
            # manifest validation refuses that combination outside tier 2
            # precisely because no host-side mitigation of W+X memory you did
            # not write is truthful.
            #
            # Note the asymmetry with the other tiers: a tier 2 plugin cannot be
            # installed imperatively. The guest needs a closure and building one
            # is a rebuild, so tier 2 plugins arrive through declaredPlugins.
            # That is a real limitation of the tier, not an oversight.
            microvm.enable = true;
            microvm.hypervisor = "cloud-hypervisor";

            requireSignature = true;

            # Stage 2: this account can ask the supervisor for a
            # signature-checked install without being root and — the point —
            # without being in nix.settings.trusted-users, which per the Nix
            # manual is root-equivalent and would make the checking moot.
            #
            # `substituters`/`trustedPublicKeys` stay empty until a signed
            # cache actually exists (see docs/plugins-roadmap.md § stage 2).
            # Until then the only installable thing is a locally signed store
            # path, which is exactly as verified.
            installers = [ config.custom.user.name ];
          };
        })

        # ── P2P substituter — STAGE 2, still not switched on ────────────────
        # The module is imported here and nowhere else: the other three hosts
        # and the ISO never see the option, so nothing needs a mkForce disable.
        #
        # Stage 1 shipped this off because a pass-through narinfo described
        # bytes we did not control, and Nix caches a narinfo for thirty days —
        # so an upstream re-compression made the adapter 404 for a month. THAT
        # REASON IS GONE. Stage 2 serves the canonical uncompressed NAR, so
        # every transport field emitted is a function of NarHash and NarSize,
        # both signed and both immutable for a given store path.
        #
        # It stays off for a different and smaller reason: `priority = 30` puts
        # the adapter ahead of cache.nixos.org for EVERY path, so enabling it
        # re-routes all substitution on this machine through a local daemon.
        # That is the intended design and it fails safe — the daemon 404s on any
        # internal error, upstream stays configured behind it, and
        # `.#p2p-substituter-protocol` asserts a build still succeeds with the
        # unit stopped — but it is the operator's call to make, not a default to
        # inherit.
        #
        # To turn it on:
        #   custom.p2pCache.enable = true;
        # then check it took:
        #   oligarchy-p2pd --config /etc/oligarchy/p2p/config.json check
        #   curl -s http://127.0.0.1:5111/nix-cache-info
        oligarchy-p2p.nixosModules.default
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
            displayGpu = "igpu"; # no dGPU on this chassis — see hasDgpu assertion in modules/platform.nix
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
              networking.firewall.blocklists.enable = lib.mkForce false;
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
        # Plugin runtime gates. Kept out of `checks` for the same reason as
        # malwareScan — they are slow and need KVM — and re-exported here
        # rather than left in the sub-flake so `nix build .#plugins-*` is the
        # one place the distro's build gates are listed. The tests themselves,
        # and the argument for why only a booted kernel can prove the W^X split
        # is enforced, live beside them in modules/oligarchy-plugins/flake.nix.
        # ════════════════════════════════════════════════════════════════════
        plugins-wx-enforcement = oligarchy-plugins.checks.${system}.wx-enforcement;
        plugins-policy-refusal = oligarchy-plugins.checks.${system}.policy-refusal;
        plugins-signed-install = oligarchy-plugins.checks.${system}.signed-install;
        plugins-tier1-runtime = oligarchy-plugins.checks.${system}.tier1-runtime;
        # Needs nested virtualisation on the builder: a microVM inside the test
        # VM. `cat /sys/module/kvm_amd/parameters/nested` must be 1 (or the Intel
        # equivalent), otherwise the inner guest falls back to emulation and the
        # boot budget stops meaning anything.
        plugins-tier2-runtime = oligarchy-plugins.checks.${system}.tier2-runtime;

        # ════════════════════════════════════════════════════════════════════
        # P2P substituter gates. Same reasoning as the plugin gates above: real
        # gates, slow (each boots a VM and runs a real substitution), so they
        # live in `packages` and are run on demand rather than by
        # `nix flake check`.
        #
        # `p2p-signature-refusal` is the one that matters. It asserts that the
        # substituter URI this module registers carries no `trusted=` parameter
        # — the flag that makes Nix accept paths signed by no trusted key,
        # silently and with exit 0. Reproduced on real hardware; see
        # docs/p2p-substituter-roadmap.md §2.1 spike 11.
        # ════════════════════════════════════════════════════════════════════
        p2p-substituter-protocol = oligarchy-p2p.checks.${system}.substituter-protocol;
        p2p-signature-refusal = oligarchy-p2p.checks.${system}.signature-refusal;
        p2p-artifact-cache = oligarchy-p2p.checks.${system}.artifact-cache;
        # The repo's first MULTI-NODE VM test. Two machines, one artifact, and
        # a leecher whose only possible source is the seeder — no upstream that
        # resolves, nothing in its store, an empty cache.
        p2p-two-node = oligarchy-p2p.checks.${system}.two-node;
        # BitTorrent. The swarm gate also asserts the NEGATIVE case — that a
        # below-threshold artifact stays out of a swarm — because this closure's
        # median NAR is 355 KiB and a swarm per NAR would be pathological.
        p2p-swarm = oligarchy-p2p.checks.${system}.swarm;
        # The claim that P2P is an enhancement and never a requirement, asserted
        # rather than stated: every peer lookup fails and the build still works.
        p2p-no-peer-fallback = oligarchy-p2p.checks.${system}.no-peer-fallback;
        # Stage 5: a host seeds what it BUILT, not only what it fetched. The
        # first gate here in which a peer supplies metadata it MINTED, so it is
        # also the first that has to prove a consumer refuses that metadata
        # when the key behind it is not trusted.
        p2p-local-signing = oligarchy-p2p.checks.${system}.local-signing;

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

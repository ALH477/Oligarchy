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

    # Chaotic-Nyx - bleeding edge packages, pre-built CachyOS kernels & binary cache
    chaotic.url = "github:chaotic-cx/nyx/nyxpkgs-unstable";

    # Hardware support
    nixos-hardware.url = "github:NixOS/nixos-hardware";

    # Custom modules
    # Vendored + patched locally: upstream's update script is `set -e` +
    # `pipefail` and dies on `grep ":"` exit-1 whenever the feed has no IPv6
    # lines — which is always (spur-astrill-vpn is IPv4-only). 196/196 runs
    # had failed for exactly that reason, leaving the ipsets empty while the
    # service reported enabled. The vendored copy (modules/demod-ip-blocker)
    # uses a pure-awk v6 filter that exits 0 on no-match. Re-point at upstream
    # only once the grep-pipeline bug is fixed there.
    demod-ip-blocker.url = "path:./modules/demod-ip-blocker";
    minecraft.url = "path:./modules/minecraft";
    android-mirror = {
      url = "path:./modules/android-mirror";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # windscribe-app — the vendor Windscribe desktop client, helper daemon and
    # CLI (custom.windscribeApp). Repackaged from the upstream GPLv2 release
    # artifact, because upstream's own Linux build drives vcpkg against a
    # custom registry and FetchContent-clones wsnet at configure time, neither
    # of which a sandboxed Nix build can do. Opt-in, defaults OFF, and
    # mutually exclusive with custom.vpn. See modules/windscribe-app/README.md.
    windscribe-app = {
      url = "path:./modules/windscribe-app";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # oligarchy-vault — user-data encryption (custom.vault.*): age blobs,
    # fscrypt directories, gocryptfs overlays. Opt-in, defaults OFF, no
    # always-on unit, so the ISO needs no mkForce.
    #
    # NOT the secrets story: activation secrets stay on sops-nix
    # (custom.secrets / modules/secrets.nix) and disks stay on LUKS. This is
    # read-write USER data, which is also why it must stay out of .mcp.json.
    oligarchy-vault = {
      url = "path:./modules/oligarchy-vault";
      inputs.nixpkgs.follows = "nixpkgs";
    };

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

    # Scrollmapper — low-footprint scripture reader (Orthodox canon default)
    # with a boot-dialogue verse. Opt-in, defaults OFF; see
    # modules/scrollmapper/README.md and its own AUDIT.md.
    #
    # follows added here even though the module's own README snippet omits
    # it: without it this path subflake pins a SECOND nixpkgs and you build
    # two closures — the exact footgun every other path input in this file
    # avoids.
    scrollmapper = {
      url = "path:./modules/scrollmapper";
      inputs.nixpkgs.follows = "nixpkgs";
    };

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

    # Reliquary — cold-storage preservation (tarball + checksum + PAR2)
    # across duplicated USB mirrors and CD-R. Opt-in, defaults OFF
    # (services.reliquary.enable). Read-write and can format raw block
    # devices / burn optical media, same category as oligarchy-forge and
    # oligarchy-vault, so it must stay out of the read-only MCP surface —
    # its `reliquary mcp` stdio server is NOT wired into .mcp.json, on
    # purpose: its own docs/ADVERSARY_REVIEW.md documents that server as
    # unauthenticated and root-equivalent for media. See
    # modules/reliquary/README.md and docs/ADVERSARY_REVIEW.md.
    reliquary = {
      url = "path:./modules/reliquary";
      inputs.nixpkgs.follows = "nixpkgs";
    };

    # warroom — the Oligarchy War Room: a Rust/Ratatui unified command center
    # over DSP, mesh, perimeter, AI and forge, driving the same `oligarchy-ctl`
    # action registry the bash control center uses rather than forking it.
    # Opt-in (`custom.warroom.enable`), defaults off.
    #
    # A *read-write* user tool, same category as oligarchy-forge and dsp-ctl, so
    # like them it must stay out of the read-only MCP surface (.#mcp-self-audit
    # fails the build if it lands in .mcp.json).
    warroom = {
      url = "path:./modules/warroom";
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
    , chaotic
    , determinate
    , nixos-hardware
    , demod-ip-blocker
    , demod-talk
    , minecraft
    , android-mirror
    , windscribe-app
    , greeting
    , boot-intro
    , blipply-assistant
    , scrollmapper
    , home-manager
    , nixos-generators
    , sops-nix
    , vm-manager
    , dsp-ctl
    , oligarchy-forge
    , oligarchy-plugins
    , oligarchy-p2p
    , oligarchy-vault
    , reliquary
    , warroom
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
        inherit inputs nixpkgs-unstable chaotic;
        # Uncomment when archibaldos is available:
        # inherit archibaldos;
        inherit vm-manager dsp-ctl oligarchy-forge mcp-servers hydramesh;
        inherit demod-talk oligarchy-vault reliquary;
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
        chaotic.nixosModules.default
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

        # custom.locale.* — the single source for language, timezone, keyboard
        # and fonts. Same reason it sits here as platform.nix and user.nix:
        # configuration.nix and home/ both SET/read these, so the declarations
        # must come first. Every sink is mkDefault and every default equals
        # today's value, so a fresh clone is unchanged by its presence.
        ./modules/locale.nix

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

        # Tailnet-only Paper server with Geyser/Floodgate crossplay
        # (services.oligarchyMinecraft). In commonModules rather than on one
        # host because it is opt-in anywhere; it defaults OFF, so unlike
        # custom.hydramesh it needs no mkForce in the ISO block below.
        ./modules/minecraft-server.nix
        # USB scrcpy phone-mirror (custom.androidMirror). Opt-in, defaults OFF,
        # so the ISO needs no mkForce. See modules/android-mirror/README.md.
        android-mirror.nixosModules.default

        # Windscribe vendor client (custom.windscribeApp). Opt-in, defaults
        # OFF, and an assertion refuses to run alongside custom.vpn — both take
        # the default route. Read-write and network-facing, so like
        # oligarchy-forge it stays out of the MCP surface.
        windscribe-app.nixosModules.default
        # User-data encryption (custom.vault.*): age blobs, fscrypt dirs,
        # gocryptfs overlays. Opt-in, defaults OFF — like android-mirror it
        # declares no always-on unit, so the ISO needs no mkForce. Turn it on
        # in configuration.nix or ~/.config/oligarchy/local.nix; see
        # modules/oligarchy-vault/README.md and example-local.nix.
        oligarchy-vault.nixosModules.default

        # Reliquary — cold-storage USB/CD-R preservation (services.reliquary.*).
        # Opt-in, defaults OFF: with enable = false this adds no automount, no
        # package, no tmpfiles rules, so no ISO mkForce needed. NOT part of the
        # MCP surface — see the flake input comment above and
        # modules/reliquary/docs/ADVERSARY_REVIEW.md for the residual risks
        # (label-based USB detection, unauthenticated destructive MCP tools)
        # before enabling this anywhere real data will touch it.
        reliquary.nixosModules.default

        # oligarchy-archive — pack a path with oligarchy-vault, then ingest it
        # into reliquary (custom.archive.enable). Opt-in, defaults OFF, no
        # ISO mkForce needed. On-demand CLI only: no timer, no service, and it
        # stops at ingest — pushing to USB / burning a CD-R stays manual. See
        # modules/oligarchy-archive.nix.
        ./modules/oligarchy-archive.nix

        # custom.mounts — UUID/PARTUUID-pinned volumes and the swapfiles that
        # live on them. A plain path module: it has no package and no source
        # tree, so there is nothing for a sub-flake to pin. Opt-in, defaults
        # OFF, and with `volumes = { }` it emits no fileSystems entry, no unit,
        # no tmpfiles rule and no swapDevices entry, so no ISO mkForce is
        # needed. Plain `fileSystems` stays correct for anything that is
        # neither removable nor a swap target — see the banner comment in
        # modules/mounts.nix for the two things it cannot do.
        ./modules/mounts.nix

        ./modules/secure-boot.nix
        ./modules/agentic-local-ai.nix
        # oligarchy-mcp.nix removed — replaced by mcp-servers.nixosModules.default
        ./modules/secrets.nix
        ./modules/security/strict-egress.nix
        # Windscribe over WireGuard (custom.vpn). Opt-in, defaults OFF, and
        # ON DEMAND even when enabled — nothing starts at boot. Must come after
        # strict-egress and ip-blocklists, whose allow.* lists it writes into.
        # See docs/vpn-windscribe.md.
        ./modules/security/dcf-spa-gate.nix
        ./modules/security/ip-blocklists.nix
        ./modules/vpn.nix
        ./modules/security/hardening.nix
        ./modules/security/malware-shield.nix
        ./modules/security/security-cli.nix
        ./modules/cpu-security.nix
        greeting.nixosModules.greeting

        # Blipply Assistant - AI Voice Assistant (integrated from local source)
        blipply-assistant.nixosModules.default

        # Scrollmapper — scripture reader + boot-dialogue verse
        # (custom.scrollmapper.*). Opt-in, defaults OFF, no always-on unit
        # beyond the boot-dialogue oneshot itself gated by bootDialogue.enable
        # (which only fires when custom.scrollmapper.enable is set) — no ISO
        # mkForce needed. See modules/scrollmapper/README.md and AUDIT.md.
        scrollmapper.nixosModules.scrollmapper

        # VM Manager - Hybrid VM management
        vm-manager.nixosModules.quickemu-vm
        vm-manager.nixosModules.dsp-vm

        # DSP Coprocessor Control — TUI/CLI tool
        dsp-ctl.nixosModules.dsp-ctl

        # oligarchy-forge — sandboxed coding-agent runner (custom.oligarchyForge.*)
        oligarchy-forge.nixosModules.default

        # warroom — the Oligarchy War Room TUI (custom.warroom.*). Defaults off;
        # with enable = false it adds no package, no unit and no session
        # variable, so the ISO needs no mkForce for it.
        warroom.nixosModules.default

        # DeMoD Voice - Local TTS and Voice Cloning
        ./modules/demod-voice/nixos-module.nix

        # NOT imported: the DSP VM this file used to gesture at is already
        # built, in full, by `vm-manager.nixosModules.dsp-vm` (option
        # `custom.vm.dsp`) — VFIO, OVMF, hugepages, RT scheduling, the NETJACK
        # and JACK bridges. modules/archibaldos-dsp-vm.nix is an older, smaller
        # take on the same hardware, and importing it would declare a SECOND
        # unit claiming the same xHCI functions; whichever started first would
        # win and the loser would fail with a device-busy error that reads like
        # a hardware fault. The guest image is `nix build .#dsp-vm-qcow`, wired
        # into `custom.vm.dsp.archibaldOS.diskImage` below.
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

        # The locale warning goes in front of the user HERE, on the ISO,
        # before they make the choice they are about to lose: a Calamares
        # install writes /etc/locale.conf + /etc/vconsole.conf + /etc/localtime
        # and adopting this flake throws all three away unless they carry them
        # across. `oligarchy-adopt` reads exactly those files back.
        echo "== Locale (what this install is about to set) =="
        if command -v localectl >/dev/null 2>&1; then
          localectl status 2>/dev/null | sed 's/^/  /' || echo "  localectl produced nothing."
        else
          echo "  localectl not present on this image."
        fi
        echo "  After installing: clone the flake, run 'oligarchy-adopt', review the"
        echo "  ~/.config/oligarchy/local.nix it writes, then:"
        echo "    sudo nixos-rebuild switch --flake .#nixos --impure"
        echo "  --impure is REQUIRED. Without it that file is silently ignored and"
        echo "  your locale reverts to America/Los_Angeles with a successful build."
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

      # Locale adoption tool (stage 2 of docs/localization-roadmap.md): reads
      # the /etc/locale.conf, /etc/vconsole.conf and /etc/localtime a stock
      # install left behind and writes the matching custom.locale.* into
      # ~/.config/oligarchy/local.nix — the override channel that already
      # exists, merged rather than clobbered. Installed onto the ISO below
      # next to oligarchy-hw-detect, and `nix run .#oligarchy-adopt`-able on an
      # already-installed system.
      oligarchyAdopt = pkgs.callPackage ./modules/locale/adopt.nix { };
    in
    {
      # ════════════════════════════════════════════════════════════════════════
      # System Configurations (one per hardware target)
      # ════════════════════════════════════════════════════════════════════════

      # Framework 16 AMD 7040 — the original target, behaviour unchanged.
      nixosConfigurations.nixos = mkHost [
        nixos-hardware.nixosModules.framework-16-7040-amd
        ./modules/hardware-configuration.nix
        { networking.hostName = "nixos"; }

        # mkDefault on `gpu`, and only on `gpu`. The control center's
        # build_fragment() (home/apps/control-center/oligarchy-ctl.sh) emits
        # `custom.platform.gpu = "..."` at NORMAL priority into state.nix, so
        # a host that also pins it at normal priority turns every `oligarchy-
        # ctl gpu-*` action into "conflicting definition values" — the gpu
        # verbs have never been able to work. (kernel-* and persona-* are
        # fine: both of their sinks are already mkDefault.)
        #
        # It is fixed here rather than left alone because hosts/asher moved
        # state.nix INTO the flake tree: the clash used to be reachable only
        # on an `--impure` run, and now it would break the ordinary pure daily
        # rebuild. `cpu`/`framework` stay pinned — nothing writes them, and
        # they are statements of fact about the chassis.
        #
        # Safe for the downstream readers: `hasDgpu`'s default is computed
        # from the RESOLVED value of `gpu` (modules/platform.nix:106), as is
        # `displayGpu`'s from `hasDgpu`, and the two assertions there read the
        # resolved values too — mkDefault changes which definition wins, not
        # what anything sees afterwards.
        { custom.platform = { gpu = nixpkgs.lib.mkDefault "amd"; cpu = "amd"; framework = true; }; }

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

        # ── DSP coprocessor guest image ────────────────────────────────────
        # Workstation only, and this sets the IMAGE, not `enable` — enabling
        # the VM stays in ~/.config/oligarchy/local.nix, because starting it
        # hands the passed-through xHCI controller to the guest and the audio
        # interfaces vanish from the host.
        #
        # Everything else about this VM (VFIO device ids, cores, hugepages,
        # NETJACK) is already configured in configuration.nix. The one thing
        # that was never reproducible was the disk: the default is a path under
        # /home that nothing builds, and the image sitting there had no EFI
        # system partition, so OVMF fell through to PXE and the VM sat in a
        # netboot loop pinning the isolated cores. It is now a derivation.
        {
          custom.vm.dsp.archibaldOS.diskImage = self.packages.x86_64-linux.dsp-vm-qcow;

          # sshd in the guest (modules/dsp-guest.nix), so the latency harness
          # can drive jackd from INSIDE the RT guest — measuring from the host
          # measures the host's scheduler, which is the thing under test.
          custom.vm.dsp.network.hostfwd = { "2222" = 22; };
        }
      ];

      # ────────────────────────────────────────────────────────────────────
      # The maintainer's actual machine: `nixos` plus hosts/asher.
      #
      # Same hardware as `nixos` above — this adds no hardware-configuration
      # and no nixos-hardware profile, only one person's toggles. Those
      # toggles used to live at ~/.config/oligarchy/local.nix and reached the
      # build only under `--impure`; pure evaluation answers `pathExists`
      # FALSE rather than erroring, so a forgotten flag silently built a
      # different machine with no warning of any kind (hosts/asher/default.nix
      # carries the incident that motivated moving them in here).
      #
      # extendModules, NOT a second mkHost list. `nixos`'s module list above
      # is ~130 lines carrying the plugin runtime, the P2P substituter, the
      # DSP VM and their reasoning; a copy would drift from it silently. This
      # way `.#nixos` is literally not edited — `git diff` proves that in one
      # line — and the fresh-clone-minimal promise it makes is untouched.
      # Same idiom the session-survives-switch and locale-contract gates use
      # further down this file.
      #
      #   sudo nixos-rebuild switch --flake .#nixos-asher     (no --impure)
      # ────────────────────────────────────────────────────────────────────
      nixosConfigurations.nixos-asher =
        self.nixosConfigurations.nixos.extendModules { modules = [ ./hosts/asher ]; };

      # Framework 13 AMD 7040 — iGPU only, no expansion-bay dGPU. Unverified
      # against real hardware (see hosts/framework13/hardware-configuration.nix).
      nixosConfigurations.nixos-fw13 = mkHost [
        nixos-hardware.nixosModules.framework-13-7040-amd
        ./hosts/framework13/hardware-configuration.nix
        {
          networking.hostName = "nixos-fw13";
          custom.platform = {
            # mkDefault so `oligarchy-ctl gpu-*` can write state.nix without
            # a conflicting-definition error — see the nixos host above.
            gpu = nixpkgs.lib.mkDefault "amd";
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
        {
          networking.hostName = "nixos-intel";
          # mkDefault on gpu — see the nixos host above (control-center
          # gpu-* actions write custom.platform.gpu at normal priority).
          custom.platform = { gpu = nixpkgs.lib.mkDefault "intel"; cpu = "intel"; framework = false; };
        }
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
          networking.hostName = "nixos-optimus";
          custom.platform = {
            # mkDefault on gpu — see the nixos host above.
            gpu = nixpkgs.lib.mkDefault "nvidia-optimus";
            cpu = "intel";
            framework = false;
            # Obtain with: lspci | grep -E 'VGA|3D|Display'  ("01:00.0" -> "PCI:1:0:0")
            nvidia.intelBusId = "PCI:0:2:0";
            nvidia.nvidiaBusId = "PCI:1:0:0";
          };
        }
      ];

      # ════════════════════════════════════════════════════════════════════════
      # Headless CI build server (custom.ciBuilder).
      #
      # The machine that runs what nothing else runs. Sixteen `nix build
      # .#<gate>` outputs and five runNixOSTest suites exist in this tree and
      # no CI system referenced any of them; this host is where they run on a
      # schedule instead of when somebody remembers.
      #
      # Not a laptop, so no nixos-hardware profile and no dGPU story. The two
      # things that matter here are nested KVM (plugins-tier2-runtime boots a
      # guest inside a guest) and disk (malwareScan realizes the whole ~48.6
      # GiB closure). modules/ci-builder.nix carries both, and reads
      # custom.platform.cpu below to pick kvm_amd vs kvm_intel rather than
      # hardcoding a vendor.
      #
      # oligarchy-plugins.nixosModules.default is imported for its microvm.nix
      # host module: custom.ciBuilder.sandbox puts the agent-review runner —
      # the only lane that reads fork pull-request content, and the only one
      # holding API keys — inside a guest. custom.plugins.enable defaults to
      # false, so importing it costs nothing else.
      # ════════════════════════════════════════════════════════════════════════
      nixosConfigurations.builder = mkHost [
        ./hosts/builder/hardware-configuration.nix
        ./modules/ci-builder.nix
        oligarchy-plugins.nixosModules.default
        {
          networking.hostName = "nixos-builder";
          # Set `cpu` to this box's actual vendor: it selects the nested-virt
          # modprobe line in modules/ci-builder.nix. `gpu` is irrelevant on a
          # headless host but the option is an enum with no "none" member.
          custom.platform = {
            # mkDefault on gpu — see the nixos host above.
            gpu = nixpkgs.lib.mkDefault "amd";
            cpu = "amd";
            framework = false;
            hasDgpu = false;
            displayGpu = "igpu";
          };

          # Headless CI box: it has no ~/.config/oligarchy and never will, by
          # construction — every one of its builds is a pure evaluation on
          # purpose. Silence configuration.nix's pure-eval advisory here so it
          # stays a signal rather than a line every gates.yml run prints.
          # The three alternate laptops deliberately keep it: they are real
          # machines somebody could sit down at and forget --impure on.
          custom.localOverrides.expected = false;

          custom.ciBuilder = {
            enable = true;
            # Provision this out of band (sops-nix, or root-owned by hand).
            # Never a path literal — that copies the token into the store.
            tokenFile = "/var/lib/secrets/github-runner-token";
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
        # The DSP coprocessor guest, as a UEFI-bootable image.
        #
        # `qcow-efi`, NOT `qcow`, and that is the whole point: the firmware in
        # modules/archibaldos-dsp-vm.nix is OVMF, and the image it replaced had
        # no EFI system partition — OVMF found nothing, fell through to PXE,
        # and sat in the netboot loop. A BIOS image here silently reproduces
        # exactly that failure.
        #
        # This exists so the guest stops being a hand-copied artifact built out
        # of tree. Three files in this repo used to look like they defined that
        # VM and none of them did; when the image stopped booting there was
        # nothing to rebuild it from.
        dsp-vm-qcow = nixos-generators.nixosGenerate {
          inherit system;
          format = "qcow-efi";
          modules = [ ./modules/dsp-guest.nix ];
        };

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
              networking.hostName = "oligarchy-iso";
              services.displayManager.sddm.enable = lib.mkForce true;
              services.displayManager.sddm.wayland.enable = lib.mkForce true;
              services.desktopManager.plasma6.enable = lib.mkForce true;
              # greetd is the production greeter but fights SDDM for tty1 on
              # the installer; force it off wherever SDDM was forced on.
              services.greetd.enable = lib.mkForce false;

              # The installer has no maintainer's home directory and is always
              # built purely, so configuration.nix's pure-eval advisory is
              # noise here — and it DOES reach this output: the ISO embeds the
              # system closure, so it evaluates system.build.toplevel, which is
              # where showWarnings sits. Silence it the way the advisory's own
              # text tells you to.
              custom.localOverrides.expected = lib.mkForce false;

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
              # Rule 9 says the ISO stays light *by default*, not merely when a
              # module's `enable` default happens to be false. Personal apps
              # (android-mirror udev rules, adbusers, scrcpy) ride a
              # `custom.desktopFeatures` default — force the whole feature off.
              custom.desktopFeatures.enablePersonalApps = lib.mkForce false;
              custom.androidMirror.enable = lib.mkForce false;
              # Same Rule 9 reading: off by default already, forced anyway so
              # the installer never carries a tunnel or a secret slot for one.
              custom.vpn.enable = lib.mkForce false;
              custom.windscribeApp.enable = lib.mkForce false;

              # fwupd is enabled above for oligarchy-hw-detect, but the weekly
              # refresh timer phones LVFS the moment the live image nets up.
              systemd.timers.fwupd-refresh.wantedBy = lib.mkForce [ ];

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
              # oligarchy-adopt ships beside it so the locale round-trip is
              # available on the installed system without fetching anything:
              # the user runs it once, after install, before the first switch.
              environment.systemPackages = [ oligarchyHwDetect oligarchyAdopt ];
              services.fwupd.enable = lib.mkForce true;
            })
          ];
        };

        default = self.packages.${system}.iso;

        # Standalone package too, so it can be pulled into a dev shell or run
        # directly on an already-installed system for a firmware check:
        #   nix run .#oligarchy-hw-detect
        oligarchy-hw-detect = oligarchyHwDetect;

        # Locale adoption tool — same shape, same reason:
        #   nix run .#oligarchy-adopt
        # Guarded by `nix build .#locale-adopt-fixtures`.
        oligarchy-adopt = oligarchyAdopt;

        # USB scrcpy game-display wrapper. Same derivation the NixOS module
        # installs when custom.androidMirror.enable is set.
        #   nix run .#phone-mirror
        phone-mirror = android-mirror.packages.${system}.default;

        # ════════════════════════════════════════════════════════════════════
        # Run the real Paper + Geyser + Floodgate stack in a scratch directory,
        # as the invoking user, without touching the system:
        #   nix run .#minecraft-server-dev -- --accept-eula
        #
        # This is the half `.#test-minecraft-server` cannot cover. That gate
        # stubs Paper — a test VM is offline and Paper ships Paperclip, which
        # downloads Mojang's server jar on first start — so it proves the
        # module's wiring and nothing about whether a Bedrock client actually
        # connects. Both share modules/minecraft-server/config.nix, so the
        # runner exercises the configuration the service will run.
        # ════════════════════════════════════════════════════════════════════
        minecraft-server-dev = pkgs.callPackage ./modules/minecraft-server/dev-run.nix { };

        # ════════════════════════════════════════════════════════════════════
        # DCL schema/value gate (§13 of docs/demod-config-layer-spec.md).
        # Pure evaluation -- no KVM, no closure -- so unlike the VM gates this
        # one is cheap enough to run on every change:
        #   nix build .#dcl-check
        #
        # The spec's §13 shells out to a `dmc-validate` binary built from
        # libdmc, which does not exist yet. This is the Nix half of the same
        # gate and it must stay in agreement with libdmc once that lands: any
        # check one side makes and the other does not is a values.json that
        # passes the build and quarantines on the device.
        #
        # Evaluated, not run in a builder, so a failure names the offending
        # option at eval time instead of burying it in build output.
        # ════════════════════════════════════════════════════════════════════
        dcl-check =
          let
            lib' = nixpkgs.lib;
            unit = import ./modules/dcl/test.nix { lib = lib'; };
            module = import ./modules/dcl/module-test.nix { lib = lib'; };
            failures = unit.failures ++ module.failures;
          in
          if failures != [ ] then
            throw
              ("dcl-check FAILED (${toString (builtins.length failures)} of "
                + "${toString (unit.total + module.total)}):\n"
                + lib'.concatMapStringsSep "\n" (f: "  - ${f.name}") failures)
          else
            pkgs.runCommand "dcl-check"
              {
                meta = with nixpkgs.lib; {
                  description = "DCL schema + value validation gate (pure eval)";
                  platforms = platforms.linux;
                };
              } ''
              mkdir -p $out
              echo "DCL: ${toString unit.passed}/${toString unit.total} library tests passed" | tee $out/report.txt
              echo "DCL: ${toString module.passed}/${toString module.total} module tests passed" | tee -a $out/report.txt
            '';

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
        # Stage 6: Nix cannot scope a signing key to a set of store paths, so
        # this adapter does. Same peer, same key, same signature — one package
        # is granted and one is not, and only the scope check can tell them
        # apart.
        p2p-peer-scope = oligarchy-p2p.checks.${system}.peer-scope;
        # Stage 6: the daemon's own assertions, and — the real content — that
        # each one FAILS when its guarantee is broken. Every bug this subsystem
        # shipped was one a passing test could not distinguish from working.
        p2p-selftest = oligarchy-p2p.checks.${system}.selftest;

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

        # ════════════════════════════════════════════════════════════════════
        # Forge agent-catalog gate — every catalogued agent still renders a
        # flake that is valid Nix.
        #
        # WHAT THIS CATCHES THAT THE UNIT TESTS DO NOT. forge-core's tests
        # assert on substrings of the rendered text, which cannot tell
        # well-formed-looking output from output that actually parses. The two
        # ways this generator breaks are exactly the two a substring check
        # misses: a template edit that emits syntactically invalid Nix, and an
        # `inputs` block that disagrees with the `outputs` function signature
        # (declare an input the function does not accept, or accept one never
        # declared, and Nix rejects the flake).
        #
        # Renders rather than builds, deliberately. `oligarchy-forge build`
        # needs a container runtime and network access to fetch each agent's
        # upstream flake; neither is available in a Nix build sandbox, and
        # requiring them would make this gate unrunnable rather than slow. The
        # `render` verb exists for this.
        #
        # Run on demand:  nix build .#forge-catalog
        # ════════════════════════════════════════════════════════════════════
        forge-catalog =
          let
            forge = oligarchy-forge.packages.${system}.oligarchy-forge;
            # The agents CI reviews with, plus the two lazily-installed ones,
            # so a template change cannot break a catalog entry unnoticed.
            agents = [ "oh-my-pi" "claude" "hermes" "opencode" "codex" ];
          in
          pkgs.runCommand "oligarchy-forge-catalog"
            {
              nativeBuildInputs = [ forge pkgs.nix ];
              meta = with nixpkgs.lib; {
                description = "Assert every forge agent renders a parseable flake";
                license = licenses.mit;
                platforms = platforms.linux;
              };
            }
            ''
              # nix-instantiate --parse only reads and parses; point its state
              # and store at the build dir anyway so it can never reach for a
              # daemon socket the sandbox does not have.
              export NIX_STATE_DIR="$PWD/nix-state"
              export NIX_STORE_DIR="$PWD/nix-store"
              export HOME="$PWD"
              mkdir -p "$NIX_STATE_DIR" "$NIX_STORE_DIR" work
              cd work

              fail=0
              for agent in ${nixpkgs.lib.concatStringsSep " " agents}; do
                printf '[project]\nname = "catalog-%s"\nagents = ["%s"]\n' \
                  "$agent" "$agent" > oligarchy-forge.toml

                if ! oligarchy-forge render > flake.nix 2> render.err; then
                  echo "FAIL  $agent — render failed:" >&2
                  cat render.err >&2
                  fail=1
                  continue
                fi

                if ! nix-instantiate --parse flake.nix > /dev/null 2> parse.err; then
                  echo "FAIL  $agent — rendered flake is not valid Nix:" >&2
                  cat parse.err >&2
                  echo "--- rendered ---" >&2
                  cat flake.nix >&2
                  fail=1
                  continue
                fi

                echo "PASS  $agent"
              done

              # A gate that inspected nothing is a failure, not a pass — the
              # same rule mcp_self_audit and the p2p selftest follow. An empty
              # agent list here would otherwise report success forever.
              if [ ${toString (builtins.length agents)} -eq 0 ]; then
                echo "FAIL: the agent list is empty; this gate checked nothing." >&2
                exit 1
              fi

              [ "$fail" -eq 0 ] || exit 1
              mkdir -p $out
              echo "all ${toString (builtins.length agents)} catalogued agents render valid Nix" > $out/report.txt
            '';

        # ════════════════════════════════════════════════════════════════════
        # Gamepad BLE bond-finisher unit tests.
        #
        # `hog_finish_bond.py`'s `classify` allowlist is what decides which
        # BlueZ device the root oneshot will call a Just-Works `Pair()` on, so
        # a widened match there silently pairs keyboards and audio sinks. These
        # stdlib unittest cases are the only gate on that allowlist, and they
        # need neither D-Bus nor KVM.
        #
        # What this gate does NOT cover, despite the name: it is a Bluetooth
        # bonding-POLICY gate, not a gamepad-FUNCTION gate. It never loads
        # hid_xpadneo, opens an evdev node, reads a HID descriptor, or checks
        # that a bonded pad delivers input at all — it would pass green with
        # xpadneo absent from the kernel entirely. The whole post-bond
        # driver/quirks/input path (see modules/gamepad-bluetooth/default.nix's
        # header comment on the xpadneo GameSir-Nova misclassification) is
        # unmeasured here on purpose: a real input assertion needs physical BLE
        # hardware and cannot run in a VM, so per CLAUDE.md's gate rule this
        # comment names the gap instead of a gate implying a guarantee it can't
        # give. `gamepad-bond-policy-tests` would be a more honest name for
        # this attribute; not renamed here because it's load-bearing in
        # CLAUDE.md, docs and muscle memory — a rename is a separate call.
        #
        # Run on demand:  nix build .#gamepad-bluetooth-tests
        # ════════════════════════════════════════════════════════════════════
        gamepad-bluetooth-tests =
          pkgs.runCommand "gamepad-bluetooth-tests"
            {
              nativeBuildInputs = [ pkgs.python3 ];
              meta = with nixpkgs.lib; {
                description = "Run the gamepad BLE bond-finisher unit tests";
                license = licenses.bsd3;
                platforms = platforms.linux;
              };
            }
            ''
              # Reference the module directory, not the flake root, so this gate
              # depends on those files alone. test_hog_finish_bond.py does
              # `from hog_finish_bond import ...`, so both must share a cwd.
              mkdir -p work
              cp ${./modules/gamepad-bluetooth}/*.py work/
              cd work
              export PYTHONDONTWRITEBYTECODE=1
              # Keep the log and the exit status independent of each other:
              # a pipeline's status is the LAST command's, so `| tee` would
              # hand this shell tee's success unless PIPESTATUS is consulted.
              # Redirecting instead makes the failure path unambiguous.
              python3 -m unittest -v > unittest.log 2>&1 || { cat unittest.log; exit 1; }
              cat unittest.log
              # A gate that inspected nothing is a FAIL (same rule as
              # mcp_self_audit): a rename that breaks discovery must not pass.
              # This MUST be an `if`, not `test -n "$ran" && test "$ran" -gt 0`:
              # under `set -e` a failing non-final command in an `&&` list only
              # short-circuits the list, and a list that ends up false is not
              # an errexit trigger — so an empty $ran passed the build green.
              ran=$(sed -n 's/^Ran \([0-9]*\) tests\?.*/\1/p' unittest.log)
              if [ -z "$ran" ] || [ "$ran" -le 0 ]; then
                echo "gamepad-bluetooth-tests: no 'Ran N tests' line found; inspected nothing" >&2
                exit 1
              fi
              mkdir -p $out
              cp unittest.log $out/
              echo "ran $ran unit tests" > $out/report.txt
            '';

        # ════════════════════════════════════════════════════════════════════
        # "A rebuild must not kill the session" — eval-only gate.
        #
        # boot-intro-player.service used to tear down the live Hyprland session
        # on every `nixos-rebuild switch`: switch-to-configuration restarts each
        # active target after activation, a finished Type=oneshot without
        # RemainAfterExit is inactive (dead), so multi-user.target started it
        # again — and TTYVHangup on /dev/tty1 took the compositor's VT with it.
        # Anything else that ever claims tty1 can reproduce that exact failure,
        # so the rule is checked over EVERY unit with TTYPath = /dev/tty1
        # rather than over that one unit by name.
        #
        # A tty1 unit must carry THREE, because each covers a different start
        # path: RemainAfterExit (the target restart finds nothing to do),
        # restartIfChanged = false (a changed unit file is not force-restarted),
        # and a PID 1 Condition* (evaluated before any exec context exists, so
        # it can decline BEFORE the vhangup — which is why the old
        # ExecCondition could not work).
        #
        # A FOURTH is required of the units that actually hang up the VT, i.e.
        # those with serviceConfig.TTYVHangup: specifically the live-session
        # guard ConditionPathExistsGlob = "!/run/systemd/sessions/*". It is
        # keyed on TTYVHangup rather than on "holds tty1" because TTYVHangup is
        # the primitive that does the damage — it is EXEC CONTEXT, applied by
        # the service manager as it sets up the process, which is after every
        # Condition* has passed and after ExecCondition would have run, so
        # nothing inside the unit's own command sequence can prevent it. A tty1
        # unit that never hangs up the VT cannot reproduce this failure and is
        # not asked for the guard.
        #
        # The fourth is separate from the third on purpose. "Some Condition*"
        # is satisfied by a once-per-boot stamp, which encodes "this boot
        # already attempted it" — NOT "a session is live". Two ordinary paths
        # slip through that: the very switch that first deploys the unit (old
        # oneshot inactive, stamp never written) and a user enabling the
        # service from inside a live session (brand-new unit, stampless boot).
        # Both kill the desktop. logind writes one file per session under
        # /run/systemd/sessions, so the negated glob is the condition that
        # actually asks "is anybody logged in"; at boot the unit runs before
        # the display manager, nothing matches, and the intro still plays.
        # Checking for the exact string is deliberate: a gate that accepts any
        # Condition* here is the gate that shipped the bug. The glob string is
        # the accepted implementation, not merely an example.
        #
        # greetd is the one exemption: it is the unit that legitimately owns
        # tty1, and its own protection is restartIfChanged = false, asserted
        # separately here.
        #
        # No KVM, no closure — but it does evaluate the whole system config.
        # Run on demand:  nix build .#session-survives-switch
        # ════════════════════════════════════════════════════════════════════
        session-survives-switch =
          let
            lib' = nixpkgs.lib;
            # extendModules, not the bare config: this is a PURE eval, so the
            # fresh-clone defaults apply and services.boot-intro.enable is
            # false — the unit this gate exists for would not exist, and the
            # gate would pass green having inspected only greetd (it did,
            # first time round). Force the intro on so its unit is always in
            # the inspected set; the require-by-name check below is what
            # makes that failure impossible to repeat quietly.
            services =
              (self.nixosConfigurations.nixos.extendModules {
                modules = [{ services.boot-intro.enable = true; }];
              }).config.systemd.services;

            # RemainAfterExit reaches the generator as a bool from Nix but as a
            # systemd boolean string from anything that writes the unit file by
            # hand; normalise rather than trust one shape.
            asBool = v:
              if builtins.isBool v then v
              else if v == null then false
              else lib'.elem (lib'.toLower (toString v)) [ "yes" "true" "on" "1" ];

            tty1 = lib'.filterAttrs
              (_: svc: (svc.serviceConfig.TTYPath or null) == "/dev/tty1")
              services;

            # The exact live-session guard, not "any Condition*". unitConfig
            # values reach here as a string from Nix but a list is legal for
            # repeated Condition* lines, so accept either shape.
            liveSessionGlob = "!/run/systemd/sessions/*";
            hasLiveSessionGuard = svc:
              let v = (svc.unitConfig or { }).ConditionPathExistsGlob or null; in
              if builtins.isList v then lib'.elem liveSessionGlob v
              else v == liveSessionGlob;

            payload = builtins.toJSON {
              tty1Units = lib'.mapAttrs
                (_: svc: {
                  remainAfterExit = asBool (svc.serviceConfig.RemainAfterExit or false);
                  # The primitive the live-session guard exists for. Same
                  # bool-or-systemd-string normalisation as RemainAfterExit.
                  ttyVHangup = asBool (svc.serviceConfig.TTYVHangup or false);
                  restartIfChanged = svc.restartIfChanged;
                  hasCondition = lib'.any
                    (k: lib'.hasPrefix "Condition" k)
                    (builtins.attrNames (svc.unitConfig or { }));
                  liveSessionGuard = hasLiveSessionGuard svc;
                })
                tty1;
              greetdRestartIfChanged = services.greetd.restartIfChanged or null;
            };

            units = pkgs.writeText "session-tty1-units.json" payload;
          in
          pkgs.runCommand "session-survives-switch"
            {
              nativeBuildInputs = [ pkgs.jq ];
              meta = with nixpkgs.lib; {
                description = "Assert no tty1 unit but greetd can vhangup the session on a switch";
                license = licenses.bsd3;
                platforms = platforms.linux;
              };
            }
            ''
              mkdir -p $out
              units=${units}

              # A gate that inspected nothing is a FAIL (same rule as
              # mcp_self_audit and forge-catalog): if the TTYPath filter ever
              # stops matching — an option rename, a unit moved to a different
              # VT — this must go red rather than green-on-empty.
              count=$(jq '.tty1Units | length' "$units")
              if [ "$count" -eq 0 ]; then
                echo "session-survives-switch: no unit with TTYPath=/dev/tty1; inspected nothing" >&2
                exit 1
              fi

              # The unit this gate was written for must be among what it
              # inspected, or the TTYPath filter (or the extendModules above)
              # has silently stopped reaching it.
              if ! jq -e '.tty1Units["boot-intro-player"]' "$units" >/dev/null; then
                echo "session-survives-switch: boot-intro-player not inspected; the gate is not looking at the unit it guards" >&2
                exit 1
              fi

              jq -r '.tty1Units | to_entries[]
                     | "\(.key)\tRemainAfterExit=\(.value.remainAfterExit)\trestartIfChanged=\(.value.restartIfChanged)\tCondition*=\(.value.hasCondition)\tTTYVHangup=\(.value.ttyVHangup)\tliveSessionGuard=\(.value.liveSessionGuard)"' \
                "$units" | tee $out/report.txt

              fail=0
              while IFS= read -r name; do
                if [ "$name" = "greetd" ]; then continue; fi
                bad=$(jq -r --arg n "$name" '
                  .tty1Units[$n]
                  | [ (if .remainAfterExit then empty else "RemainAfterExit" end)
                    , (if .restartIfChanged then "restartIfChanged=false" else empty end)
                    , (if .hasCondition then empty else "a Condition* in unitConfig" end)
                    , (if (.ttyVHangup | not) or .liveSessionGuard then empty else "unitConfig.ConditionPathExistsGlob = \"!/run/systemd/sessions/*\" (required because this unit sets TTYVHangup: that is exec context, applied by the service manager after every Condition* has passed and after ExecCondition would have run, so nothing inside the unit can stop it — and a once-per-boot stamp alone still vhangups a live session on the switch that first deploys the unit)" end)
                    ] | join(", ")' "$units")
                if [ -n "$bad" ]; then
                  echo "FAIL  $name holds /dev/tty1 and is missing: $bad" >&2
                  fail=1
                else
                  echo "PASS  $name"
                fi
              done < <(jq -r '.tty1Units | keys[]' "$units")

              # greetd owns tty1 on purpose; restarting it kills the Hyprland
              # session it spawned (not a separately-managed logind session),
              # which is the crash configuration.nix's restartIfChanged=false
              # exists to prevent.
              greetd=$(jq -r '.greetdRestartIfChanged' "$units")
              echo "greetd.restartIfChanged=$greetd" >> $out/report.txt
              if [ "$greetd" != "false" ]; then
                echo "FAIL  greetd.restartIfChanged is '$greetd', expected false" >&2
                fail=1
              fi

              [ "$fail" -eq 0 ] || exit 1
              echo "inspected $count unit(s) on /dev/tty1" >> $out/report.txt
            '';

        # ════════════════════════════════════════════════════════════════════
        # hypr-session restore fixtures.
        #
        # `hypr-session restore` relaunches the windows from the last saved
        # session, which means it builds a `hyprctl dispatch exec` line per
        # entry out of /proc-derived argv. The quoting in those lines is the
        # whole correctness story and it cannot be exercised live in a sandbox
        # (no compositor), so `--dry-run` prints them and this gate diffs them
        # against checked-in expectations. Bash and jq only: no KVM, no X, no
        # compositor.
        #
        # Run on demand:  nix build .#hypr-session-tests
        # ════════════════════════════════════════════════════════════════════
        hypr-session-tests =
          let
            script = ./home/scripts/hypr-session.sh;
            fixtures = ./home/scripts/testdata/hypr-session;
          in
          pkgs.runCommand "hypr-session-tests"
            {
              nativeBuildInputs = [ pkgs.bash pkgs.jq pkgs.coreutils ];
              meta = with nixpkgs.lib; {
                description = "Assert hypr-session restore --dry-run matches its fixtures";
                license = licenses.bsd3;
                platforms = platforms.linux;
              };
            }
            ''
              mkdir -p $out work
              cd work
              # The script defaults its session file under $HOME; give it one
              # that exists so a --from-less code path can never write to /.
              export HOME="$PWD"

              found=0
              fail=0
              for fixture in ${fixtures}/*.json; do
                [ -e "$fixture" ] || continue
                name=$(basename "$fixture" .json)
                expected="${fixtures}/$name.expected"
                found=$((found+1))

                if [ ! -e "$expected" ]; then
                  echo "FAIL  $name — no $name.expected beside the fixture" >&2
                  fail=1
                  continue
                fi

                if ! bash ${script} restore --dry-run --from "$fixture" > "$name.actual" 2> "$name.err"; then
                  echo "FAIL  $name — restore --dry-run exited non-zero:" >&2
                  cat "$name.err" >&2
                  fail=1
                  continue
                fi

                if diff -u "$expected" "$name.actual"; then
                  echo "PASS  $name"
                else
                  echo "FAIL  $name — dry-run output differs from $name.expected" >&2
                  fail=1
                fi
              done

              # Inspected nothing is a FAIL: a renamed fixture directory must
              # not quietly turn this gate into a no-op.
              if [ "$found" -eq 0 ]; then
                echo "hypr-session-tests: no *.json fixtures found; inspected nothing" >&2
                exit 1
              fi

              [ "$fail" -eq 0 ] || exit 1
              echo "$found hypr-session restore fixture(s) match their expected dry-run output" \
                > $out/report.txt
            '';

        # ════════════════════════════════════════════════════════════════════
        # Captive portal scripts — modules/captive-portal/tests/run.sh.
        #
        # The watcher, captive-login and nmtui-portal are plain bash files
        # configured through CAPTIVE_* env vars precisely so this gate can run
        # the SAME files against a fake nmcli: the open-once-per-episode state
        # machine, the re-arm on full/none, the display-vs-TTY split and the
        # nmtui hand-off are all asserted here without a VM. What only a
        # booted NetworkManager can prove (that the probe actually flips to
        # PORTAL) lives in tests/default.nix as .#test-captive-portal.
        #
        # Run on demand:  nix build .#captive-portal-tests
        # ════════════════════════════════════════════════════════════════════
        captive-portal-tests =
          pkgs.runCommand "captive-portal-tests"
            {
              nativeBuildInputs = [
                pkgs.bash pkgs.shellcheck pkgs.coreutils pkgs.findutils pkgs.gnugrep pkgs.gnused
                pkgs.util-linux pkgs.jq pkgs.openssh pkgs.python3
              ];
              meta = with nixpkgs.lib; {
                description = "Assert the captive-portal scripts and the portal-VM orchestrator against fakes; bash, no KVM";
                license = licenses.bsd3;
                platforms = platforms.linux;
              };
            }
            ''
              mkdir -p $out
              cp -r ${./modules/captive-portal} src
              chmod -R u+w src
              # The sandbox has no /usr/bin/env; the shebangs must resolve.
              patchShebangs src/bin src/tests

              find src/bin src/tests -type f -print0 | xargs -0 shellcheck
              echo "shellcheck: clean" | tee $out/report.txt

              bash src/tests/run.sh 2>&1 | tee -a $out/report.txt
              test "''${PIPESTATUS[0]}" -eq 0

              # The portal-VM orchestrator (Design F): real jq, sha256sum and
              # ssh-keygen; fakes for everything that needs root or hardware.
              bash src/tests/vm-run.sh 2>&1 | tee -a $out/report.txt
              test "''${PIPESTATUS[0]}" -eq 0
            '';

        # ════════════════════════════════════════════════════════════════════
        # oligarchy-adopt fixtures — docs/localization-roadmap.md §8.
        #
        # The adoption tool reads the /etc a stock install left behind and
        # writes custom.locale.* into ~/.config/oligarchy/local.nix. Both
        # halves are testable without a VM: the fixtures are fake filesystem
        # roots, and the assertion is an exact diff of the Nix it emits.
        #
        # A fixture carrying `existing-local.nix` is the merge case — the tool
        # must not clobber a file the user already has (the control centre's
        # wholesale overwrite of state.nix is the failure this avoids) — so it
        # is run with --out against a COPY and the resulting file is diffed,
        # not stdout.
        #
        # Run on demand:  nix build .#locale-adopt-fixtures
        # ════════════════════════════════════════════════════════════════════
        locale-adopt-fixtures =
          let
            fixtures = ./modules/locale/tests/fixtures;
          in
          pkgs.runCommand "locale-adopt-fixtures"
            {
              nativeBuildInputs = [ oligarchyAdopt pkgs.coreutils pkgs.diffutils ];
              meta = with nixpkgs.lib; {
                description = "Assert oligarchy-adopt turns fixture /etc trees into the expected custom.locale.*";
                license = licenses.bsd3;
                platforms = platforms.linux;
              };
            }
            ''
              mkdir -p $out work
              cd work
              # The tool defaults --out under $HOME; give it one that exists so
              # no code path can ever write to /.
              export HOME="$PWD"

              found=0
              fail=0
              for case in ${fixtures}/*/; do
                [ -d "$case" ] || continue
                name=$(basename "$case")
                expected="$case/expected.nix"
                found=$((found+1))

                if [ ! -e "$expected" ]; then
                  echo "FAIL  $name — no expected.nix beside the fixture" >&2
                  fail=1
                  continue
                fi

                if [ -e "$case/expect-exit-2" ]; then
                  # Refusal case: the tool must exit 2, write NOTHING (the
                  # file is byte-identical to existing-local.nix) and leave no
                  # backup behind. `if !` keeps the intended non-zero exit
                  # from aborting the loop under the builder's set -e.
                  cp "$case/existing-local.nix" "$name.local.nix"
                  chmod u+w "$name.local.nix"
                  rc=0
                  oligarchy-adopt --root "$case" --out "$name.local.nix" > "$name.log" 2>&1 || rc=$?
                  if [ "$rc" -ne 2 ]; then
                    echo "FAIL  $name — expected exit 2 (refusal), got $rc:" >&2
                    cat "$name.log" >&2
                    fail=1
                    continue
                  fi
                  if [ -e "$name.local.nix.bak-adopt" ]; then
                    echo "FAIL  $name — a backup was written despite the refusal" >&2
                    fail=1
                    continue
                  fi
                  if diff -u "$expected" "$name.local.nix"; then
                    echo "PASS  $name (refused, file untouched)"
                  else
                    echo "FAIL  $name — --out was modified despite the refusal" >&2
                    fail=1
                  fi
                  continue
                fi

                if [ -e "$case/existing-local.nix" ]; then
                  # Merge case: run against a writable copy and diff the RESULT.
                  cp "$case/existing-local.nix" "$name.local.nix"
                  chmod u+w "$name.local.nix"
                  if ! oligarchy-adopt --root "$case" --out "$name.local.nix" > "$name.log" 2>&1; then
                    echo "FAIL  $name — oligarchy-adopt exited non-zero:" >&2
                    cat "$name.log" >&2
                    fail=1
                    continue
                  fi
                  actual="$name.local.nix"
                else
                  if ! oligarchy-adopt --root "$case" --stdout > "$name.actual" 2> "$name.err"; then
                    echo "FAIL  $name — oligarchy-adopt --stdout exited non-zero:" >&2
                    cat "$name.err" >&2
                    fail=1
                    continue
                  fi
                  actual="$name.actual"
                fi

                if diff -u "$expected" "$actual"; then
                  echo "PASS  $name"
                else
                  echo "FAIL  $name — emitted Nix differs from expected.nix" >&2
                  fail=1
                fi
              done

              # Inspected nothing is a FAIL: a renamed fixture directory must
              # not quietly turn this gate into a no-op.
              if [ "$found" -eq 0 ]; then
                echo "locale-adopt-fixtures: no fixture directories found; inspected nothing" >&2
                exit 1
              fi

              [ "$fail" -eq 0 ] || exit 1
              echo "$found oligarchy-adopt fixture(s) emit exactly their expected.nix" > $out/report.txt
            '';
      }
      # ══════════════════════════════════════════════════════════════════════
      # The tests/default.nix VM suite, surfaced as `packages.test-<name>`.
      #
      # These are `pkgs.testers.runNixOSTest` and therefore need KVM. They go
      # in `packages`, NOT in `checks`, and that placement is deliberate:
      # `checks.${system}` is currently KVM-free (it builds the system
      # toplevel and nothing else), which is what lets a runner without
      # /dev/kvm still run `nix flake check`. Folding five VM tests into
      # `checks` would silently take that property away.
      #
      # Same reasoning as the plugins-*/p2p-* gates above, which are also
      # packages rather than checks. CI runs them by name on the self-hosted
      # builder — see .github/workflows/gates.yml.
      # ══════════════════════════════════════════════════════════════════════
      // (
        let
          vmTests = import ./tests {
            inherit pkgs;
            inherit (nixpkgs) lib;
            # The portal-VM tests build a guest with microvm.nix's guest module.
            microvm = oligarchy-plugins.inputs.microvm;
          };
        in
        nixpkgs.lib.mapAttrs'
          (name: drv: nixpkgs.lib.nameValuePair "test-${name}" drv)
          vmTests
      );

      # ════════════════════════════════════════════════════════════════════════
      # Locale contract gate — docs/localization-roadmap.md §8.
      #
      # `legacyPackages`, NOT `packages`, and that placement is the whole
      # reason this file has a legacyPackages output at all.
      #
      # The payload below is a `pkgs.writeText` with 25 complete NixOS + Home
      # Manager evaluations interpolated into it, so it is forced as soon as
      # anything computes this derivation's `drvPath` — building is not
      # required. `nix flake check` forces `drvPath` of every `packages.*`
      # entry (that is how it reports "package X does not evaluate"), so
      # living in `packages` would have put 25 full system evals on the
      # critical path of every `nix flake check` — i.e. every push to main via
      # gates.yml, the `flake_check` MCP tool's 900 s budget, and the
      # validation command in CLAUDE.md. "Run on demand" would have been false.
      #
      # `nix flake check` checks the SYSTEM names under `legacyPackages` and
      # deliberately does not recurse into the values, so from here the 25
      # evals happen only when someone actually asks for this gate.
      # `nix build .#locale-contract` still resolves: the default attr-path
      # search tries `packages.<system>.<name>` and then
      # `legacyPackages.<system>.<name>`, so the invocation is unchanged.
      #
      # Contrast `session-survives-switch`, which stays in `packages`: it does
      # ONE evaluation of one host and costs roughly what `nix flake check`
      # was already paying.
      #
      # ── what it asserts ──────────────────────────────────────────────────
      # Evaluates every nixosConfiguration under five languages and asserts
      # the things that are silent when they break. Pure eval: no KVM, no
      # closure — but it does evaluate 25 complete system configs (Home
      # Manager included), so it is minutes, not seconds.
      #
      # The line this gate exists for is the MIRROR: services.xserver.xkb
      # (X11/XWayland), Hyprland's input.kb_layout (Wayland) and the console
      # keymap (the TTY and the LUKS prompt) are three different consumers of
      # one keyboard description, and they used to be three independent
      # literals. Nothing at runtime complains when they disagree — you find
      # out at the LUKS prompt, in the dark, typing a passphrase on a layout
      # nobody chose. So: they are all derived from custom.locale.keyboard.*,
      # and this asserts the derivation still holds on every host.
      #
      # Anti-vacuity, per mcp_self_audit's two rules: a combination that was
      # not inspected is a SKIP that is REPORTED and counts against the
      # required 25, and the mirror check itself must have run at least once
      # (a Home-Manager-less host would otherwise let the most valuable
      # assertion in the file pass having compared nothing).
      #
      # Run on demand:  nix build .#locale-contract
      # ════════════════════════════════════════════════════════════════════════
      legacyPackages.${system} = {
        locale-contract =
          let
            lib' = nixpkgs.lib;

            hosts = [ "nixos" "nixos-fw13" "nixos-intel" "nixos-optimus" "builder" ];

            # en-US is the maintainer's machine and must stay a no-op; de-DE
            # is a Latin layout change; ja-JP is CJK fonts + an input method;
            # ar-SA is RTL + a third script; xx-pseudo is the test locale the
            # module is required to warn about rather than reject.
            langs = [
              { l = "en-US"; tz = "America/Los_Angeles"; kb = "us"; }
              { l = "de-DE"; tz = "Europe/Berlin"; kb = "de"; }
              { l = "ja-JP"; tz = "Asia/Tokyo"; kb = "jp"; }
              { l = "ar-SA"; tz = "Asia/Riyadh"; kb = "ara"; }
              { l = "xx-pseudo"; tz = "UTC"; kb = "us"; }
            ];

            # The keymap name modules/locale.nix gives the ckbcomp derivation
            # it compiles from the SAME xkb description services.xserver.xkb
            # and Hyprland read. Every combination here leaves
            # custom.locale.keyboard.consoleKeyMap null, so every combination
            # must land on this derivation and not on a literal string (a
            # literal would mean the TTY/LUKS half stopped being derived).
            wantConsoleKeyMap = "xkb-console-keymap";

            inspect = host: lang:
              let
                cfg = (self.nixosConfigurations.${host}.extendModules {
                  modules = [{
                    # mkForce, not plain definitions. On any machine that has
                    # run `oligarchy-adopt`, ~/.config/oligarchy/local.nix
                    # sets these same three options at normal priority, and
                    # `nix build .#locale-contract --impure` would then throw
                    # "conflicting definitions" for all 25 rows at once. The
                    # gate is asking "given THIS language, does everything
                    # downstream agree?", which is exactly an override.
                    custom.locale.language = lib'.mkForce lang.l;
                    custom.locale.timeZone = lib'.mkForce lang.tz;
                    custom.locale.keyboard.layout = lib'.mkForce lang.kb;
                  }];
                }).config;

                # `a.b.c or null` returns null if ANY hop is missing, which is
                # what makes this safe on a host that carries no Hyprland (or
                # no Home Manager at all).
                hmUser = cfg.custom.user.name;
                hm = cfg.home-manager.users.${hmUser} or null;
                hyprKb = hm.wayland.windowManager.hyprland.settings.input.kb_layout or null;

                defaultLocale = cfg.i18n.defaultLocale;
                # supportedLocales entries carry a /CHARSET suffix that
                # defaultLocale does not; compare the locale half only.
                supported = cfg.i18n.supportedLocales or [ ];

                km = cfg.console.keyMap;

                fontNames = map (p: lib'.toLower (p.name or "")) cfg.fonts.packages;
              in
              {
                inherit host;
                language = lang.l;
                requestedTimeZone = lang.tz;
                requestedLayout = lang.kb;
                # Forced explicitly: nothing else in a pure eval forces
                # assertions, and a gate that never evaluated one inspected
                # nothing. Warnings are recorded, not failed — §4.4 says
                # xx-pseudo and a fontless input method are warnings.
                failedAssertions = map (a: a.message) (lib'.filter (a: !a.assertion) cfg.assertions);
                warnings = cfg.warnings;
                inherit defaultLocale;
                # Near-tautological on 25.11, where i18n.supportedLocales is
                # itself derived from i18n.defaultLocale — kept because it
                # costs nothing and stops being tautological the moment any
                # host or profile sets supportedLocales by hand, which is the
                # case where glibc silently generates no locale and falls
                # back to C.
                defaultLocaleSupported =
                  lib'.any (e: builtins.head (lib'.splitString "/" e) == defaultLocale) supported;
                timeZone = cfg.time.timeZone;
                xkbLayout = cfg.services.xserver.xkb.layout;
                # Recorded as a NAME, never as the derivation itself: the row
                # is serialised to JSON, and the point of comparison is which
                # keymap was chosen, not its store path.
                consoleKeyMap =
                  if km == null then "<null>"
                  else if lib'.isDerivation km then (km.name or "<unnamed derivation>")
                  else toString km;
                # Informational. modules/locale.nix keeps this FALSE and sets
                # console.keyMap to the compiled derivation instead, so this
                # is reported for the reviewer rather than asserted.
                consoleUseXkbConfig = cfg.console.useXkbConfig;
                hmPresent = hm != null;
                hyprKbLayout = hyprKb;
                cjkFont = lib'.any (n: lib'.hasInfix "cjk" n) fontNames;
                notoFont = lib'.any (n: lib'.hasInfix "noto" n) fontNames;
              };

            # Every recorded field is tryEval'd on its OWN, rather than the
            # row as a whole, so a combination that fails to evaluate reports
            # WHICH attributes died instead of an opaque "evaluation failed".
            # builtins.tryEval cannot hand back the message, so naming the
            # attributes is the most a pure eval can say — but it is enough to
            # reproduce by hand, and it distinguishes "this host has no
            # Hyprland" from "the whole module system blew up".
            #
            # The override fields above are deliberately NOT inside this net:
            # they are mkForce, so a local.nix conflict cannot reach here at
            # all, and if one ever did the right outcome is a hard error
            # naming the option, not 25 identical SKIPs.
            probe = host: lang:
              let
                tried = lib'.mapAttrs
                  (_: v: builtins.tryEval (builtins.deepSeq v v))
                  (inspect host lang);
                broken = lib'.attrNames (lib'.filterAttrs (_: r: !r.success) tried);
              in
              if broken == [ ] then
                (lib'.mapAttrs (_: r: r.value) tried) // { skipped = false; }
              else {
                inherit host;
                language = lang.l;
                requestedTimeZone = lang.tz;
                requestedLayout = lang.kb;
                skipped = true;
                reason = "could not evaluate: ${lib'.concatStringsSep ", " broken}";
              };

            payload = pkgs.writeText "locale-contract.json"
              (builtins.toJSON {
                rows = lib'.concatMap (h: map (l: probe h l) langs) hosts;
              });
          in
          pkgs.runCommand "locale-contract"
            {
              nativeBuildInputs = [ pkgs.jq ];
              TZDATA = pkgs.tzdata;
              WANT_CONSOLE_KEYMAP = wantConsoleKeyMap;
              meta = with nixpkgs.lib; {
                description = "Assert custom.locale.* drives xkb, Hyprland, console, fonts and tz on every host";
                license = licenses.bsd3;
                platforms = platforms.linux;
              };
            }
            ''
              mkdir -p $out
              rows=${payload}
              : > $out/report.txt

              total=$(jq '.rows | length' "$rows")
              if [ "$total" -ne 25 ]; then
                echo "locale-contract: $total combination(s) in the payload, expected 25 (5 hosts x 5 languages) — inspected nothing, or only part of the matrix" >&2
                exit 1
              fi

              fail=0
              mirrors=0

              while IFS= read -r row; do
                get() { printf '%s\n' "$row" | jq -r "$1"; }

                host=$(get '.host')
                lang=$(get '.language')
                want_tz=$(get '.requestedTimeZone')

                if [ "$(get '.skipped')" != "false" ]; then
                  echo "SKIP  $host/$lang — $(get '.reason // "unknown"')" | tee -a $out/report.txt >&2
                  fail=1
                  continue
                fi

                defloc=$(get '.defaultLocale')
                supported=$(get '.defaultLocaleSupported')
                tz=$(get '.timeZone')
                xkb=$(get '.xkbLayout')
                hypr=$(get '.hyprKbLayout // "<absent>"')
                keymap=$(get '.consoleKeyMap')
                usexkb=$(get '.consoleUseXkbConfig')
                cjk=$(get '.cjkFont')
                noto=$(get '.notoFont')
                nassert=$(get '.failedAssertions | length')
                nwarn=$(get '.warnings | length')

                echo "$host/$lang	tz=$tz	locale=$defloc	xkb=$xkb	hypr=$hypr	keymap=$keymap	useXkbConfig=$usexkb	cjk=$cjk	noto=$noto	assertions=$nassert	warnings=$nwarn" >> $out/report.txt

                bad=""

                if [ "$nassert" -ne 0 ]; then
                  bad="$bad; failing assertions: $(get '.failedAssertions | join(" | ")')"
                fi

                # Warnings are legitimate here (xx-pseudo is a test locale,
                # §4.4), so they are recorded rather than failed — but they go
                # in the report where a reviewer sees them.
                if [ "$nwarn" -ne 0 ]; then
                  get '.warnings[] | "        warning: \(.)"' >> $out/report.txt
                fi

                if [ "$supported" != "true" ]; then
                  bad="$bad; i18n.defaultLocale=$defloc is not in the derived i18n.supportedLocales (glibc will not generate it and falls back to C silently)"
                fi

                if [ "$tz" != "$want_tz" ]; then
                  bad="$bad; time.timeZone=$tz but custom.locale.timeZone asked for $want_tz"
                fi

                if [ ! -e "$TZDATA/share/zoneinfo/$tz" ]; then
                  bad="$bad; time.timeZone=$tz names no zone in tzdata"
                fi

                # The TTY/LUKS half of the mirror. Every combination here
                # leaves custom.locale.keyboard.consoleKeyMap null, so the
                # console keymap must be the derivation modules/locale.nix
                # COMPILES from the same xkb description — not a literal, and
                # not the unset "us" default. A string here means the TTY and
                # the LUKS prompt quietly stopped following the layout.
                if [ "$keymap" != "$WANT_CONSOLE_KEYMAP" ]; then
                  bad="$bad; console.keyMap=$keymap, expected the compiled $WANT_CONSOLE_KEYMAP — the TTY and the LUKS prompt are no longer derived from custom.locale.keyboard"
                fi

                # THE mirror assertion.
                if [ "$hypr" = "<absent>" ]; then
                  echo "        mirror not checked on $host/$lang (no Home Manager Hyprland config)" >> $out/report.txt
                else
                  mirrors=$((mirrors+1))
                  if [ "$xkb" != "$hypr" ]; then
                    bad="$bad; MIRROR: services.xserver.xkb.layout=$xkb but Hyprland input.kb_layout=$hypr — two literals again"
                  fi
                fi

                case "$lang" in
                  ja-JP)
                    [ "$cjk" = "true" ] || bad="$bad; ja-JP pulls no CJK font into fonts.packages (tofu everywhere, no error)"
                    ;;
                  ar-SA)
                    [ "$noto" = "true" ] || bad="$bad; ar-SA pulls no noto font into fonts.packages (no Arabic coverage)"
                    ;;
                esac

                if [ -n "$bad" ]; then
                  echo "FAIL  $host/$lang$bad" >&2
                  fail=1
                else
                  echo "PASS  $host/$lang"
                fi
              done < <(jq -c '.rows[]' "$rows")

              # The mirror is the reason this gate exists; if no combination
              # could check it, it passed having compared nothing.
              if [ "$mirrors" -eq 0 ]; then
                echo "locale-contract: the xkb/Hyprland mirror was never checked — no host exposed wayland.windowManager.hyprland.settings.input.kb_layout" >&2
                fail=1
              fi

              [ "$fail" -eq 0 ] || exit 1
              echo "inspected $total combination(s); mirror checked on $mirrors of them" >> $out/report.txt
            '';

        # ════════════════════════════════════════════════════════════════════════
        # Captive portal contract — the things that are silent when they break.
        #
        # Same shape as locale-contract: pure eval of the real host config, no
        # KVM, no closure. Three evaluations (base, https loginUrl, autoOpen
        # off), so it sits in legacyPackages beside locale-contract and never
        # lands on `nix flake check`'s critical path.
        #
        # What it asserts on nixosConfigurations.nixos:
        #   - the module is ENABLED there (a gate that inspected a disabled
        #     module inspected nothing)
        #   - NetworkManager's connectivity URI is exactly the probe the option
        #     describes and is plain http
        #   - the probe host and login host are on strictEgress.allow.domains,
        #     so enforcing egress can never make every portal read as "limited"
        #   - the watcher unit exists, restarts always with no start-rate
        #     limit, and is wanted by the graphical session; the CLIs are on
        #     PATH; the browser kind is an isolated one; opens are rate-limited
        #   - an https loginUrl is REFUSED by the module's own assertion
        #   - autoOpen = false really removes the unit
        #
        # Run on demand:  nix build .#captive-portal-contract
        # ════════════════════════════════════════════════════════════════════════
        captive-portal-contract =
          let
            lib' = nixpkgs.lib;
            base = self.nixosConfigurations.nixos.config;
            override = m: (self.nixosConfigurations.nixos.extendModules { modules = [ m ]; }).config;
            withHttps = override { custom.network.captivePortal.loginUrl = lib'.mkForce "https://neverssl.com/"; };
            noAuto = override { custom.network.captivePortal.autoOpen = lib'.mkForce false; };

            # Design F, as the shipped config would run it with kind = microvm.
            withVm = override { custom.network.captivePortal.browser.kind = lib'.mkForce "microvm"; };
            vmCfg = withVm.custom.network.captivePortal.microvm;
            g = vmCfg.build.guest.config;
            gStore = g.fileSystems."/nix/store" or { };
            vmSvc = withVm.systemd.services.captive-vm or null;
            viewer = withVm.systemd.services.captive-vm-viewer or null;
            dspCore = override {
              custom.network.captivePortal.browser.kind = lib'.mkForce "microvm";
              custom.network.captivePortal.microvm.cpu = lib'.mkForce 1;
              boot.kernelParams = [ "isolcpus=0,1" ];
            };
            storeKey = override {
              custom.network.captivePortal.browser.kind = lib'.mkForce "microvm";
              custom.network.captivePortal.microvm.publicKey = lib'.mkForce "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeFakeFakeFakeFakeFakeFakeFakeFakeFake";
              custom.network.captivePortal.microvm.signingKeyFile = lib'.mkForce "/nix/store/0000000000000000000000000000000-key";
            };
            failedWith = cfg: frag: lib'.any (a: !a.assertion && lib'.hasInfix frag a.message) cfg.assertions;

            cp = base.custom.network.captivePortal;
            conn = base.networking.networkmanager.settings.connectivity or { };
            loginHost = lib'.head (lib'.splitString "/" (lib'.removePrefix "http://" cp.loginUrl));
            egress = base.networking.firewall.strictEgress.allow.domains;
            pkgNames = map (p: p.name or "") base.environment.systemPackages;
            onPath = n: lib'.elem n pkgNames;
            svc = base.systemd.user.services.captive-portal-watch or null;

            payload = pkgs.writeText "captive-portal-contract.json" (builtins.toJSON {
              enabled = cp.enable;
              uri = conn.uri or null;
              uriIsProbe = (conn.uri or "") == "http://${cp.probe.host}${cp.probe.path}";
              uriPlainHttp = lib'.hasPrefix "http://" (conn.uri or "");
              probeEnabled = conn.enabled or false;
              responseSet = (conn.response or "") != "";
              loginPlainHttp = lib'.hasPrefix "http://" cp.loginUrl;
              egressHasProbeHost = lib'.elem cp.probe.host egress;
              egressHasLoginHost = lib'.elem loginHost egress;
              cliOnPath = onPath "captive-login" && onPath "nmtui-portal" && onPath "captive-portal-watch";
              watcherPresent = svc != null;
              watcherRestartAlways = (svc.serviceConfig.Restart or null) == "always";
              watcherInSession = lib'.elem "graphical-session.target" (svc.wantedBy or [ ]);
              watcherNoStartLimit = (svc.unitConfig.StartLimitIntervalSec or null) == 0;
              # The audit's headline finding: the portal page never opens in
              # the everyday profile. kind = command is the VM gate's seam and
              # a deliberate choice elsewhere; xdg-open is the one that is not.
              browserIsolated = cp.browser.kind != "xdg-open";
              rateLimited = cp.minInterval >= 30;
              httpsRefused = lib'.any
                (a: !a.assertion && lib'.hasInfix "must be plain http://" a.message)
                withHttps.assertions;
              autoOpenOffRemovesUnit = !(noAuto.systemd.user.services ? captive-portal-watch);

              # ── Design F: the portal microVM ──
              # Off by default until its gates are green on the builder.
              vmOffByDefault = cp.browser.kind != "microvm" && !(base.systemd.services ? captive-vm);
              vmGuestModuleWired = vmCfg.guestModule != null;
              vmGuestStoreIsVerity = (gStore.device or "") == "/dev/mapper/nixstore" && (gStore.fsType or "") == "erofs";
              vmGuestVerityInInitrd = g.boot.initrd.systemd.dmVerity.enable && g.boot.initrd.systemd.services ? captive-verity;
              vmGuestNoWritableDisk = g.microvm.volumes == [ ] && g.microvm.shares == [ ] && g.microvm.writableStoreOverlay == null;
              vmGuestNoVsock = g.microvm.vsock.cid == null;
              vmGuestNoSsh = !g.services.openssh.enable;
              vmGuestNoNix = !g.nix.enable;
              vmGuestNoDocker = !(g.virtualisation.docker.enable or false);
              vmGuestNoLockdownClaim = !(lib'.any (p: lib'.hasPrefix "lockdown=" p) g.boot.kernelParams);
              vmOrchestratorNotify = (vmSvc.serviceConfig.Type or null) == "notify";
              vmOrchestratorBounded = !(lib'.elem "CAP_SYS_ADMIN" (vmSvc.serviceConfig.CapabilityBoundingSet or [ "CAP_SYS_ADMIN" ]));
              vmViewerOffline = (viewer.serviceConfig.PrivateNetwork or false) == true;
              vmViewerOwnVt = lib'.hasPrefix "/dev/tty" (viewer.serviceConfig.TTYPath or "");
              vmTapUnmanaged = lib'.elem "interface-name:cp0" withVm.networking.networkmanager.unmanaged;
              vmPolkitScoped = lib'.hasInfix "captive-vm.service" withVm.security.polkit.extraConfig;
              vmDspCoreRefused = failedWith dspCore "isolated (isolcpus)";
              vmStoreKeyRefused = failedWith storeKey "must not be a Nix store path";
            });
          in
          pkgs.runCommand "captive-portal-contract"
            {
              nativeBuildInputs = [ pkgs.jq ];
              meta = with nixpkgs.lib; {
                description = "Assert the captive-portal module is wired into nixos: probe URI, egress allowlist, watcher unit, https refusal";
                license = licenses.bsd3;
                platforms = platforms.linux;
              };
            }
            ''
              mkdir -p $out
              j=${payload}
              cp "$j" $out/contract.json
              fail=0
              want() { # want <field> — must be true
                if [ "$(jq -r ".$1" "$j")" = true ]; then
                  echo "PASS  $1" | tee -a $out/report.txt
                else
                  echo "FAIL  $1 = $(jq -c ".$1" "$j")" | tee -a $out/report.txt >&2
                  fail=1
                fi
              }
              # Anti-vacuity first: everything below is about an enabled module.
              want enabled
              want uriIsProbe
              want uriPlainHttp
              want probeEnabled
              want responseSet
              want loginPlainHttp
              want egressHasProbeHost
              want egressHasLoginHost
              want cliOnPath
              want watcherPresent
              want watcherRestartAlways
              want watcherInSession
              want watcherNoStartLimit
              want browserIsolated
              want rateLimited
              want httpsRefused
              want autoOpenOffRemovesUnit
              for k in vmOffByDefault vmGuestModuleWired vmGuestStoreIsVerity vmGuestVerityInInitrd \
                vmGuestNoWritableDisk vmGuestNoVsock vmGuestNoSsh vmGuestNoNix vmGuestNoDocker \
                vmGuestNoLockdownClaim vmOrchestratorNotify vmOrchestratorBounded vmViewerOffline \
                vmViewerOwnVt vmTapUnmanaged vmPolkitScoped vmDspCoreRefused vmStoreKeyRefused; do
                want "$k"
              done
              echo "uri: $(jq -r .uri "$j")" >> $out/report.txt
              [ "$fail" -eq 0 ] || { echo "captive-portal-contract: FAILED" >&2; exit 1; }
              echo "captive-portal-contract: 35 checks passed" | tee -a $out/report.txt
            '';

        # ════════════════════════════════════════════════════════════════════════
        # Portal-VM activation reference — Design F, the build half.
        #
        # Builds the guest image nixosConfigurations.nixos would boot with
        # browser.kind = "microvm" (Firefox closure + erofs: minutes, disk, no
        # KVM) and asserts, against the REAL artifacts:
        #   - the verity tree verifies the store disk, and re-deriving the tree
        #     from the disk with the manifest's own recipe gives the same root:
        #     the reference is reproducible from the image, not just recorded
        #   - the launcher's baked reference is sha256(manifest.json)
        #   - kernel/initrd/tree/policy hashes in the manifest match the files
        #   - the real launcher's `verify` accepts it, and refuses a manifest
        #     that is one byte off (a copy, via a patched wrapper env)
        #   - a manifest signature from a throwaway key verifies; a tampered
        #     copy, another namespace and another key do not
        #   - the cmdline claims no lockdown (a no-op on this kernel) and does
        #     not already carry captive.verity=
        # Tamper detection of dm-verity itself is exercised on a small image
        # with the same flags, since flipping bytes in a 1 GiB copy buys nothing.
        #
        # Determinism across builds: `nix build .#captive-vm-image --rebuild`
        # rebuilds the manifest and fails if it differs.
        #
        # Run on demand:  nix build .#captive-vm-reference
        # ════════════════════════════════════════════════════════════════════════
        captive-vm-image =
          ((self.nixosConfigurations.nixos.extendModules {
            modules = [{ custom.network.captivePortal.browser.kind = nixpkgs.lib.mkForce "microvm"; }];
          }).config.custom.network.captivePortal.microvm.build.manifest);

        captive-vm-reference =
          let
            build = (self.nixosConfigurations.nixos.extendModules {
              modules = [{ custom.network.captivePortal.browser.kind = nixpkgs.lib.mkForce "microvm"; }];
            }).config.custom.network.captivePortal.microvm.build;
            m = build.manifest;
          in
          pkgs.runCommand "captive-vm-reference"
            {
              nativeBuildInputs = with pkgs; [ cryptsetup jq openssh coreutils gnused gnugrep erofs-utils ];
              meta = with nixpkgs.lib; {
                description = "Assert the portal-VM manifest is reproducible from its image and the launcher enforces it";
                license = licenses.bsd3;
                platforms = platforms.linux;
              };
            }
            ''
              mkdir -p $out
              M=${m}/manifest.json
              fail=0
              ok() { echo "PASS  $1" | tee -a $out/report.txt; }
              no() { echo "FAIL  $1" | tee -a $out/report.txt >&2; fail=1; }
              t() { local n=$1; shift; if "$@"; then ok "$n"; else no "$n"; fi; }
              f() { local n=$1; shift; if "$@"; then no "$n"; else ok "$n"; fi; }
              q() { jq -er "$1" "$M"; }
              s() { sha256sum "$1" | cut -c1-64; }

              root=$(q .store.verity.root)
              store=$(q .store.path)
              tree=$(q .store.verity.hashTree)
              t "verity: the tree verifies the store disk" veritysetup verify "$store" "$tree" "$root"
              salt=$(s "$store")
              uuid=$(printf '%s' "$salt" | sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12}).*/\1-\2-\3-\4-\5/')
              veritysetup format --hash=sha256 --data-block-size=4096 --hash-block-size=4096 \
                --salt="$salt" --uuid="$uuid" "$store" again.img > again.txt
              t "verity: re-deriving from the disk gives the manifest's root" \
                test "$(sed -n 's/^Root hash:[[:space:]]*//p' again.txt)" = "$root"
              t "verity: and a byte-identical tree" cmp -s again.img "$tree"

              ref=$(cat ${m}/reference)
              t "reference: is sha256(manifest.json)" test "$ref" = "$(s "$M")"
              t "reference: is the value baked into the launcher" \
                grep -q "CVM_REFERENCE.*$ref" ${build.launcher}/bin/captive-vm-run
              t "hashes: kernel" test "$(s "$(q .kernel.path)")" = "$(q .kernel.sha256)"
              t "hashes: initrd" test "$(s "$(q .initrd.path)")" = "$(q .initrd.sha256)"
              t "hashes: hash tree" test "$(s "$tree")" = "$(q .store.verity.hashTreeSha256)"
              t "hashes: egress policy" test "$(s "$(q .policy.nft)")" = "$(q .policy.nftSha256)"
              f "cmdline: claims no lockdown (a no-op on the stock kernel)" grep -q 'lockdown=' <<< "$(q .cmdline)"
              f "cmdline: does not carry captive.verity= itself" grep -q 'captive.verity=' <<< "$(q .cmdline)"
              t "cmdline: boots the guest's own init" grep -q 'init=/nix/store/' <<< "$(q .cmdline)"

              # The real launcher, pointed at a scratch run dir and a stand-in
              # /dev/kvm (the sandbox has none).
              mkdir -p dev run
              ln -s /dev/null dev/kvm
              t "launcher: verify accepts the built image" \
                env CVM_RUNDIR=$PWD/run CVM_DEVDIR=$PWD/dev ${build.launcher}/bin/captive-vm-run verify
              cp "$M" m2.json
              sed -i 's/reboot=t/reboot=T/' m2.json
              t "launcher: the tampered copy really differs" test "$(s m2.json)" != "$ref"
              # Same script, same reference, same env as the wrapper — only the
              # manifest differs, so a refusal can only be the reference check.
              f "launcher: refuses a manifest one byte off" \
                env CVM_RUNDIR=$PWD/run CVM_DEVDIR=$PWD/dev CVM_MANIFEST=$PWD/m2.json \
                CVM_REFERENCE="$ref" CVM_QEMU=/nonexistent \
                bash ${./modules/captive-portal/bin/captive-vm-run.sh} verify

              ssh-keygen -q -t ed25519 -N "" -f key
              ssh-keygen -q -t ed25519 -N "" -f other
              ssh-keygen -Y sign -q -f key -n oligarchy-captive-vm < "$M" > sig
              printf 'captive-vm namespaces="oligarchy-captive-vm" %s\n' "$(cut -d' ' -f1,2 key.pub)" > allowed
              printf 'captive-vm namespaces="oligarchy-captive-vm" %s\n' "$(cut -d' ' -f1,2 other.pub)" > allowed-other
              v() { ssh-keygen -Y verify -f "$1" -I captive-vm -n "$2" -s sig < "$3" > /dev/null 2>&1; }
              t "signature: verifies" v allowed oligarchy-captive-vm "$M"
              f "signature: a tampered manifest does not verify" v allowed oligarchy-captive-vm m2.json
              f "signature: another namespace does not verify" v allowed other-namespace "$M"
              f "signature: another key does not verify" v allowed-other oligarchy-captive-vm "$M"

              # dm-verity's own tamper detection, with the manifest's exact flags.
              mkdir -p tiny/store
              for i in $(seq 1 64); do head -c $((i * 997)) /dev/urandom > tiny/store/f$i; done
              mkfs.erofs -T 0 --all-root tiny.erofs tiny/store > /dev/null
              ts=$(s tiny.erofs)
              tu=$(printf '%s' "$ts" | sed -E 's/^(.{8})(.{4})(.{4})(.{4})(.{12}).*/\1-\2-\3-\4-\5/')
              veritysetup format --hash=sha256 --data-block-size=4096 --hash-block-size=4096 \
                --salt="$ts" --uuid="$tu" tiny.erofs tiny.tree > tiny.txt
              troot=$(sed -n 's/^Root hash:[[:space:]]*//p' tiny.txt)
              t "verity/tamper: clean image verifies" veritysetup verify tiny.erofs tiny.tree "$troot"
              printf '\x55' | dd of=tiny.erofs bs=1 seek=$(( $(stat -c %s tiny.erofs) / 2 + 7 )) conv=notrunc status=none
              f "verity/tamper: one flipped byte is caught" veritysetup verify tiny.erofs tiny.tree "$troot"

              cp "$M" $out/manifest.json
              echo "reference: $ref" | tee -a $out/report.txt
              [ "$fail" -eq 0 ] || { echo "captive-vm-reference: FAILED" >&2; exit 1; }
              echo "captive-vm-reference: all checks passed" | tee -a $out/report.txt
            '';

        # ════════════════════════════════════════════════════════════════════════
        # Network posture contract — docs/networking-design-spec (Designs C–E).
        #
        # Pure eval of nixosConfigurations.nixos (plus three cheap overrides
        # for the trusted-Wi-Fi module). Every line here is a thing
        # configuration.nix says in one place and nothing at runtime complains
        # about when it drifts back:
        #   - resolved carries no global "~." routing domain
        #   - NM: connection.mdns = 0 and connection.llmnr = 0 (Avahi owns
        #     .local; resolved must not be a second responder)
        #   - NM: wifi.cloned-mac-address = stable (the real MAC never goes
        #     out on a public SSID) while ethernet stays preserve
        #   - Avahi is still on with nss-mdns (the reason mdns=0 is safe)
        #   - resolved still on, dnssec allow-downgrade, DoT opportunistic
        #     (the combination the captive-portal VM gate was written against)
        #   - firewall: no 22 and no 443 in the interface-agnostic list; 22 on
        #     tailscale0 only
        #   - custom.network.trustedWifi renders `psk=$VAR` (never a literal),
        #     pins DNS with ignore-auto-dns, refuses a literal-looking pskVar,
        #     refuses profiles with no secrets source and refuses a secrets
        #     file that lives in the world-readable store
        #
        # Run on demand:  nix build .#network-posture-contract
        # ════════════════════════════════════════════════════════════════════════
        network-posture-contract =
          let
            lib' = nixpkgs.lib;
            c = self.nixosConfigurations.nixos.config;
            nm = c.networking.networkmanager;
            cc = nm.connectionConfig;
            fw = c.networking.firewall;

            # Lists of modules, not `//`: an attrset update would replace the
            # whole `custom` attribute and silently drop the sample profile.
            override = ms: (self.nixosConfigurations.nixos.extendModules { modules = ms; }).config;
            sample = {
              custom.network.trustedWifi.home = {
                ssid = "Contract Net";
                pskVar = "HOME_PSK";
                dns = [ "9.9.9.9" "149.112.112.112" ];
                priority = 20;
              };
            };
            # A runtime path, never a store path: the module refuses those
            # (asserted below) because the store is world-readable. Nothing is
            # read at eval; the profile is rendered with `$HOME_PSK`.
            source = { custom.network.trustedWifiSecretsFile = "/run/secrets/wifi-env"; };
            storePath = override [ sample { custom.network.trustedWifiSecretsFile = pkgs.writeText "wifi-env" "HOME_PSK=unused\n"; } ];
            withSecrets = override [ sample source ];
            rendered = withSecrets.networking.networkmanager.ensureProfiles.profiles.home;
            noSource = override [ sample ];
            # pskVar = "hunter2" must die in the option type, which is a throw
            # tryEval can see once the value is forced.
            literalPsk = builtins.tryEval (builtins.deepSeq
              (override [ sample source { custom.network.trustedWifi.home.pskVar = lib'.mkForce "hunter2"; } ])
                .networking.networkmanager.ensureProfiles.profiles
              true);

            payload = pkgs.writeText "network-posture-contract.json" (builtins.toJSON {
              # ── stage 3: firewall + profiles ──
              sshNotGlobal = !(lib'.elem 22 fw.allowedTCPPorts);
              tlsNotGlobal = !(lib'.elem 443 fw.allowedTCPPorts);
              sshOnTailscale = lib'.elem 22 (fw.interfaces.tailscale0.allowedTCPPorts or [ ]);
              profileRendersPskVar = rendered.wifi-security.psk == "$HOME_PSK";
              profileIsWifiPsk = rendered.wifi-security.key-mgmt == "wpa-psk" && rendered.wifi.ssid == "Contract Net";
              profilePinsDns = rendered.ipv4.dns == "9.9.9.9;149.112.112.112;" && rendered.ipv4.ignore-auto-dns == true;
              profilePriority = rendered.connection.autoconnect-priority == 20;
              profileEnvFileWired = lib'.length withSecrets.networking.networkmanager.ensureProfiles.environmentFiles == 1;
              noSecretsSourceRefused = lib'.any
                (a: !a.assertion && lib'.hasInfix "no secrets source" a.message)
                noSource.assertions;
              literalPskRefused = !literalPsk.success;
              storePathSecretsRefused = lib'.any
                (a: !a.assertion && lib'.hasInfix "must not be a Nix store path" a.message)
                storePath.assertions;
              # ── stage 2: resolver, mDNS, MAC ──
              networkManagerOn = nm.enable;
              resolvedOn = c.services.resolved.enable;
              noGlobalRoutingDomain = !(lib'.elem "~." c.services.resolved.domains);
              dnssecAllowDowngrade = c.services.resolved.dnssec == "allow-downgrade";
              dotOpportunistic = c.services.resolved.dnsovertls == "opportunistic";
              mdnsOff = (cc."connection.mdns" or null) == 0;
              llmnrOff = (cc."connection.llmnr" or null) == 0;
              wifiMacStable = (cc."wifi.cloned-mac-address" or null) == "stable";
              ethernetMacPreserve = (cc."ethernet.cloned-mac-address" or null) == "preserve";
              avahiOn = c.services.avahi.enable && c.services.avahi.nssmdns4;
              nmUsesResolved = nm.dns == "systemd-resolved";
            });
          in
          pkgs.runCommand "network-posture-contract"
            {
              nativeBuildInputs = [ pkgs.jq ];
              meta = with nixpkgs.lib; {
                description = "Assert the LAN posture in configuration.nix: no ~. routing domain, Avahi alone on mDNS, LLMNR off, stable Wi-Fi MAC";
                license = licenses.bsd3;
                platforms = platforms.linux;
              };
            }
            ''
              mkdir -p $out
              j=${payload}
              cp "$j" $out/contract.json
              fail=0
              want() {
                if [ "$(jq -r ".$1" "$j")" = true ]; then
                  echo "PASS  $1" | tee -a $out/report.txt
                else
                  echo "FAIL  $1 = $(jq -c ".$1" "$j")" | tee -a $out/report.txt >&2
                  fail=1
                fi
              }
              # Anti-vacuity: the posture is about NM + resolved + Avahi all on.
              want networkManagerOn
              want resolvedOn
              want avahiOn
              want nmUsesResolved
              want noGlobalRoutingDomain
              want dnssecAllowDowngrade
              want dotOpportunistic
              want mdnsOff
              want llmnrOff
              want wifiMacStable
              want ethernetMacPreserve
              want sshNotGlobal
              want tlsNotGlobal
              want sshOnTailscale
              want profileRendersPskVar
              want profileIsWifiPsk
              want profilePinsDns
              want profilePriority
              want profileEnvFileWired
              want noSecretsSourceRefused
              want literalPskRefused
              want storePathSecretsRefused
              [ "$fail" -eq 0 ] || { echo "network-posture-contract: FAILED" >&2; exit 1; }
              echo "network-posture-contract: 22 checks passed" | tee -a $out/report.txt
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

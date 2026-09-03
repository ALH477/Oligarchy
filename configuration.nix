{ config, pkgs, lib, inputs, nixpkgs-unstable, ... }:

{
  # ============================================================================
  # NixOS Production Configuration — Framework 16 AMD
  # ============================================================================

  imports = [
    ./modules/audio.nix
    # boot-intro options come from the boot-intro flake module
    # (modules/boot-intro/modules/core.nix), wired in flake.nix. The standalone
    # ./modules/boot-intro.nix is an older monolithic copy declaring the same
    # services.boot-intro options — importing both is a duplicate-option eval
    # error, so it is intentionally not imported here.
    ./modules/dcf-community-node.nix
    ./modules/dcf-identity.nix
    ./modules/dcf-tray.nix
    ./modules/dcf-mesh-agent.nix
    ./modules/hypr-controller/nixos-module.nix
    ./modules/terminus-dev.nix
  ]
  # Optional local overrides, both at absolute paths OUTSIDE the repo so a
  # fresh clone never sees them (Nix's local-flake source filtering excludes
  # gitignored files from the evaluated source tree entirely — an in-repo
  # override file would vanish from `nix build`/`nixos-rebuild switch` even on
  # this machine the moment it's gitignored, which is why these live under
  # ~/.config/oligarchy instead of the old in-repo oligarchy-local.nix):
  #   local.nix — hand-maintained personal toggles (steam, malware-shield,
  #     the DSP VM, the personal package list, etc.), never touched by tooling.
  #   state.nix — written by the control center (kernel/gpu/persona picks);
  #     kept separate because the control center wholesale-overwrites its file
  #     on every UI action, which would silently wipe local.nix if shared.
  #
  # NOTE: hardcodes "asher" rather than config.custom.user.name — `imports` is
  # evaluated to determine what `config` even contains, so referencing `config`
  # here is a circular dependency ("infinite recursion encountered").
  ++ lib.optional (builtins.pathExists "/home/asher/.config/oligarchy/local.nix")
       "/home/asher/.config/oligarchy/local.nix"
  ++ lib.optional (builtins.pathExists "/home/asher/.config/oligarchy/state.nix")
       "/home/asher/.config/oligarchy/state.nix";

  options = {
    custom.steam.enable = lib.mkEnableOption "Steam and gaming support";
  };

  config =
    let
      # Shared derivation: PATH binary and sudoers NOPASSWD entry must match.
      xhci-recover = pkgs.writeShellScriptBin "xhci-recover" ''
        set -euo pipefail
        if [ "''${EUID:-$(id -u)}" -ne 0 ]; then
          echo "run as root: sudo $0 [PCI_ADDR ...]" >&2
          exit 1
        fi
        if [ "$#" -gt 0 ]; then
          DEVS=("$@")
        else
          DEVS=(0000:c5:00.3)
        fi
        log() { echo "[xhci-recover $(${pkgs.coreutils}/bin/date +%H:%M:%S)] $*"; }
        rebind() {
          local dev=$1
          if [ ! -e /sys/bus/pci/devices/$dev ]; then
            log "WARN: $dev not present"
            return 1
          fi
          if [ -e /sys/bus/pci/drivers/xhci_hcd/$dev ]; then
            log "unbind $dev"
            echo "$dev" > /sys/bus/pci/drivers/xhci_hcd/unbind || true
            ${pkgs.coreutils}/bin/sleep 2
          fi
          log "bind $dev"
          if ! echo "$dev" > /sys/bus/pci/drivers/xhci_hcd/bind 2>/dev/null; then
            log "bind failed — remove + rescan $dev"
            echo 1 > "/sys/bus/pci/devices/$dev/remove" || true
            ${pkgs.coreutils}/bin/sleep 1
            echo 1 > /sys/bus/pci/rescan
            ${pkgs.coreutils}/bin/sleep 2
          fi
        }
        for d in "''${DEVS[@]}"; do
          rebind "$d" || true
        done
        ${pkgs.coreutils}/bin/sleep 2
        if [ -d /var/lib/systemd/rfkill ]; then
          for f in /var/lib/systemd/rfkill/*bluetooth*; do
            [ -f "$f" ] || continue
            echo 0 > "$f" || true
          done
        fi
        ${pkgs.util-linux}/bin/rfkill unblock bluetooth 2>/dev/null || true
        log "USB devices now:"
        ${pkgs.usbutils}/bin/lsusb || true
        log "Framework kbd / audio probe:"
        ${pkgs.usbutils}/bin/lsusb | ${pkgs.gnugrep}/bin/grep -E '32ac:0012|17cc:|0499:|0e8d:' \
          || log "(not yet re-enumerated — replug or wait)"
        log "done"
      '';
    in
    {
      # ──────────────────────────────────────────────────────────────────────────
      # Nix build parallelism
      # ──────────────────────────────────────────────────────────────────────────
      # The defaults (max-jobs = auto = 16, cores = 0 = unlimited) are wrong on
      # this box: `isolcpus=0,1` surrenders two CPUs to the DSP guest, so only
      # 14 are schedulable, and Nix would otherwise run 16 derivations x 16
      # threads against them. Observed load average 87 on a full closure build,
      # with the desktop unusable.
      #
      # 3 x 4 = 12 threads at peak, leaving 2 CPUs of headroom. Keep the product
      # at or below 12 if you retune; raising max-jobs costs more than raising
      # cores, because each job also holds memory.
      nix.settings = {
        max-jobs = 3;
        cores = 4;
      };

      # Android SDK license acceptance
      nixpkgs.config.android_sdk.accept_license = true;

      # Enable nix-ld to run dynamically linked executables (required for Android build tools)
      programs.nix-ld.enable = true;
      programs.nix-ld.libraries = with pkgs; [
        stdenv.cc.cc
        zlib
        glib
        openssl
        curl
        libxml2
      ];

      # ──────────────────────────────────────────────────────────────────────────
      # DeMoD Boot Intro
      # ──────────────────────────────────────────────────────────────────────────
      services.boot-intro = {
        enable = lib.mkDefault false;

        # Theme selection — matches home/themes/default.nix's desktop themes
        # Options: demod, catppuccin, nord, rosepine, gruvbox, dracula, tokyo, phosphor, steam
        theme = "tokyo";

        # Branding
        titleText = "Initiating Oligarchy";
        # Framework hardware check: genuine Framework boards (custom.platform.
        # framework, set per-host in flake.nix) get told which chassis they
        # are via custom.platform.frameworkModel; the Intel/Optimus hosts get
        # the plain branding line.
        bottomText =
          if config.custom.platform.framework
          then "Framework ${config.custom.platform.frameworkModel or "16"} · NixOS · Hyprland"
          else "NixOS · The War Machine";

        # Logo overlay (DeMoD logo from assets)
        logoImage = ./assets/demod-logo.png;
        logoScale = 0.5;

        # Audio source — MIDI gets synthesized, audio files normalized
        # soundFile = ./assets/boot-chime.mid;
        # Or use a wav/mp3/flac:
        soundFile = ./assets/modretro.wav;
        volume = 40;
        # Optional: Background video (loops behind waveform)
        # Re-enable once assets/modretro.mp4 is added & git-tracked (absent from
        # the repo, so referencing it fails pure flake eval).
        # backgroundVideo = ./assets/modretro.mp4;

        # Visual tuning
        resolution = "2560x1600"; # Match your Framework 16 display
        waveformOpacity = 0.7;
        fadeDuration = 2.0;
      };


      # ──────────────────────────────────────────────────────────────────────────
      # DCF Stack Configuration
      # ──────────────────────────────────────────────────────────────────────────

      # Community Node - Set your actual node ID
      custom.dcfCommunityNode = {
        enable = false;
        nodeId = "alh477"; # Your actual node ID
        openFirewall = true;
      };
      # Identity Service - Enable for production
      custom.dcfIdentity = {
        enable = false;
        domain = "dcf.demod.ltd";
        port = 4000;
        dataDir = "/var/lib/demod-identity";
        # When enabling: sops runtime path, NEVER a repo file (that copies
        # into /nix/store). See modules/dcf-identity.nix secretsFile docs.
        secretsFile = "/run/secrets/dcf-id-env";
      };
      # System Tray Controller
      services.dcf-tray.enable = false;

      # DCF Mesh Agent (commented by default — enable when peer mesh endpoint ready)
      # services.dcf-mesh-agent = {
      #   enable = true;
      #   nodeId = "0x00A1";
      #   channel = "duet";
      #   udpPort = 7801;
      #   peers = [ "127.0.0.1:7802" ];
      #   agentName = "oligarchy-hermes";
      # };

      # DCF-Hypr Agent — HyprController Android remote (commented by default,
      # see modules/hypr-controller/README.md). Enable only when actually
      # pairing a controller device.
      # services.dcf-hypr-agent = {
      #   enable = true;
      #   udpPort = 7100;
      #   spaGated = true;    # gate 7100 behind a signed knock before putting
      #                       # this on an untrusted LAN (forces IPv4; needs a
      #                       # key in /etc/dcf-spa/peers). Not needed when the
      #                       # only path in is Tailscale or USB-gadget.
      # };

      # ──────────────────────────────────────────────────────────────────────────
      # Local AI Stack (Ollama)
      # ──────────────────────────────────────────────────────────────────────────
      # enable + preset are owned by the active persona (modules/personas.nix);
      # acceleration is set per-GPU by modules/platform.nix. The system persona
      # defaults to "dev" (AI on, pewdiepie), reproducing the prior behaviour.

      # Greeting is opt-in (services.oligarchyGreeting.enable). If/when enabled,
      # its "press any key" launches the unified control center instead of a bare
      # terminal. mkDefault so it's harmless while the greeting is disabled.
      services.oligarchyGreeting.tui.launchCommand = lib.mkDefault "oligarchy-control";

      # ──────────────────────────────────────────────────────────────────────────
      # Local AI agent surface
      # ──────────────────────────────────────────────────────────────────────────
      # OpenClaw (insecure remote-plugin gateway, LAN-exposed, static token) was
      # removed. The legacy monolithic Python `oligarchy-mcp` server was replaced
      # by a set of dedicated, read-only Rust MCP servers — one per OS aspect,
      # plus the dedicated `ports-sec` API/port auditor. See
      # docs/mcp-servers-roadmap.md.
      # Blipply consumes the MCP over stdio; Claude Code reads .mcp.json which
      # points each aspect entry at `oligarchy-mcp <aspect>` (the umbrella binary
      # exec-spawns the matching aspect server).
      custom.mcpServers.enable = lib.mkDefault false;

      # Blipply local voice assistant (Whisper -> ollama -> Piper). Calls the MCP
      # over stdio for read-only system tools.
      # DISABLED by default: the MCP tool-calling Rust (src/mcp.rs + ollama
      # tool-calling) is merged but UNBUILT and may need a compile-fix pass. Flip
      # to true and rebuild to compile + iterate. Keeping it off keeps the default
      # build green and avoids the heavy whisper/onnx/gtk4 compile.
      oligarchy.blipply.enable = false;

      # ──────────────────────────────────────────────────────────────────────────
      # Audio Configuration — Pure PipeWire (no X11-based audio remnants)
      # ──────────────────────────────────────────────────────────────────────────
      # Disable the custom audio module (replaced with standard PipeWire config below)
      custom.audio.enable = false;

      services.pipewire = {
        enable = true;
        alsa.enable = true;
        alsa.support32Bit = true;
        pulse.enable = true;
        jack.enable = true;

        # Explicitly disable X11 bell (last potential X11 audio tie)
        extraConfig.pipewire."10-disable-x11-bell" = {
          "context.properties" = {
            "module.x11.bell" = false;
          };
        };

        # Low-latency settings (replicates former lowLatency.enable)
        # min-quantum 64 ≈ 1.3 ms @ 48 kHz — a guitar rig must be ALLOWED to go
        # low. Default stays 256 so desktop apps don't burn CPU; only clients
        # that explicitly request a small quantum (guitarix, JACK apps) get it.
        # The "20-low-latency" clock block (rate/quantum/min/max) is owned entirely
        # by the active persona — see modules/personas.nix.

        # High-quality Bluetooth codecs (replicates bluetooth.highQualityCodecs)
        wireplumber.extraConfig."50-high-quality-bt" = {
          "monitor.bluez.properties" = {
            "bluez5.codecs" = [ "sbc" "sbc_xq" "ldac" "aptx" "aptx_hd" "aptx_ll" "aac" "lc3" "opus" ];
            "bluez5.enable-sbc-xq" = true;
            "bluez5.enable-msbc" = true;
            "bluez5.enable-hw-volume" = true;
          };
        };

        # Disable libcamera monitor (replicates disableLibcameraMonitor — prevents CPU polling for OBS/v4l2loopback)
        wireplumber.extraConfig."99-disable-libcamera" = {
          "monitor.libcamera.enabled" = false;
        };
      };

      # ──────────────────────────────────────────────────────────────────────────
      # Memory Configuration
      # ──────────────────────────────────────────────────────────────────────────
      # Disk swap, LOW priority — deliberately below zram (100) so it only
      # engages once the ~11 GiB zram cushion is actually exhausted. This is a
      # backup for oversized local-LLM loads (a 30-70B model can outrun RAM +
      # zram combined), not everyday overflow — the RT-audio latency concern
      # that originally kept disk swap off (see the zram block below) mostly
      # doesn't apply here: the "studio" persona already turns AI off
      # (custom.persona.active=studio -> aiEnable=false in modules/personas.nix),
      # so heavy LLM use and low-latency audio work aren't expected to
      # coincide. Generic device only — nofail so a missing/unmounted
      # swapfile never blocks boot:
      #   /swapfile on the root ext4 (nvme1n1, system drive) — plain
      #   NixOS-managed swapfile; `size` makes NixOS create it on switch.
      #
      # A second, machine-specific swapDevices entry (an ad hoc
      # udisks2-automounted external drive) plus the activation script that
      # creates it (nodatacow, since btrfs swapfiles must be) both live in
      # ~/.config/oligarchy/local.nix now, not here — see the local-override
      # comment at the top of this file. Both option types merge cleanly
      # across separate modules, so that entry just appends to this list on
      # machines where the override file is present.
      swapDevices = [
        {
          device = "/swapfile";
          size = 32768; # 32 GiB
          priority = 10;
        }
      ];
      #
      # ── zram: OOM cushion without the disk cost or the RT-audio penalty ──────
      # There was NO swap of any kind on this box (22 GiB RAM, swapDevices empty
      # above), so a memory spike had nowhere to go: `nix build` of the system
      # toplevel fanned out to all 16 cores, exhausted RAM, and the OOM killer
      # took the display down with it.
      #
      # zram is the right shape for this machine specifically: it is compressed
      # swap *in RAM*, so it adds headroom with zero disk I/O — which is why it
      # doesn't reintroduce the latency stalls that a /swapfile would inflict on
      # the isolcpus/NETJACK RT audio path (the reason vm.swappiness is 10 and
      # disk swap stayed off). zstd runs ~3:1 on build heap, so 50% of RAM of
      # address space costs roughly 3-4 GiB of real RAM when full.
      #
      # This is a cushion, not a licence to run unbounded builds. The actual
      # cause is the `nix.settings` max-jobs/cores cap ABOVE — which was already
      # written but is NOT live on the running system: /etc/nix/nix.custom.conf
      # still reads `cores = 0` / `max-jobs = auto`, i.e. the tree is ahead of
      # the deployed generation. Until a switch lands, pass the caps per
      # invocation (`nix build --max-jobs 3 --cores 4 ...`).
      zramSwap = {
        enable = true;
        algorithm = "zstd";
        memoryPercent = 50; # ~11 GiB of compressed swap space on 22 GiB RAM
        priority = 100; # prefer zram over any disk swap added later
      };

      # ── AI-stack dedicated swap + container memory accounting ────────────────
      # See modules/agentic-local-ai.nix for the module that owns these options.
      # Swap tier ordering: zram (100) > AI-dedicated (50) > generic backup (10).
      # The AI-only swapfile lives on root ext4 (always mounted), and the
      # container mem/swap caps prevent Ollama from eating the entire system.
      services.ollamaAgentic.dedicatedSwap = {
        enable = lib.mkDefault false;
        sizeGB = 24;
        priority = 50;
      };
      services.ollamaAgentic.containerMemoryLimitGB = 18;

      # ── Hibernate support ────────────────────────────────────────────────────
      # upower.criticalPowerAction below is "Hibernate". Without resumeDevice +
      # resume_offset the kernel writes a hibernation image it can NEVER resume
      # from: critical battery = hard crash + lost session on next boot.
      # Fill these in on the running machine, then uncomment:
      #
      #   findmnt -no UUID -T /swapfile
      #     → boot.resumeDevice = "/dev/disk/by-uuid/<UUID>";
      #   sudo filefrag -v /swapfile | awk '$1=="0:" {print substr($4,1,length($4)-2)}'
      #     → add "resume_offset=<N>" to boot.kernelParams
      #
      # boot.resumeDevice = "/dev/disk/by-uuid/CHANGE-ME";
      # boot.kernelParams = [ "resume_offset=CHANGE-ME" ];  # merge into list above
      warnings = lib.optional
        (config.boot.resumeDevice == ""
          && builtins.elem config.services.upower.criticalPowerAction [ "Hibernate" "HybridSleep" ])
        "Oligarchy: upower criticalPowerAction is ${config.services.upower.criticalPowerAction} but boot.resumeDevice is unset — hibernation cannot resume. See the hibernate block near swapDevices in configuration.nix.";

      boot.kernel.sysctl = {
        # Deliberately left at 10 even though zramSwap is now on. The usual
        # "raise swappiness to 100+ with zram" advice targets desktops; this box
        # runs RT audio, and 10 keeps the kernel biased toward dropping page
        # cache before touching anon pages. It does NOT defeat the zram cushion:
        # swappiness only sets the reclaim *preference*, so under genuine anon
        # pressure (a runaway nix eval heap) the kernel still swaps to zram
        # rather than invoking the OOM killer.
        "vm.swappiness" = 10;
        "vm.dirty_ratio" = 10;
        "vm.dirty_background_ratio" = 5;
      };

      # ──────────────────────────────────────────────────────────────────────────
      # Package Overlays (removed broken pipewire override — libcamera now disabled via WirePlumber config)
      # ──────────────────────────────────────────────────────────────────────────
      nixpkgs.overlays = [
        (final: prev: {
          unstable = import nixpkgs-unstable {
            system = prev.system;
            config.allowUnfree = true;
          };
        })
      ];

      # ──────────────────────────────────────────────────────────────────────────
      # Gaming
      # ──────────────────────────────────────────────────────────────────────────
      custom.steam.enable = lib.mkDefault false;

      # Isolate Steam + games from swap (DDR5-only): under memory pressure
      # games were dipping into the disk swapfile / zram and stalling hard
      # enough to effectively die. MemorySwapMax=0 on this slice blocks that
      # cgroup from swapping at all (zram counts as swap here too) — an
      # allocation that would have spilled to swap instead OOM-kills just
      # the game, instead of thrashing the whole system into unplayability.
      #
      # Launched via a systemd-run wrapper rather than by wrapping
      # programs.steam.package itself: the steam NixOS module calls
      # `.override` on cfg.package internally (to inject
      # extraCompatPackages etc.), which a runCommand/symlinkJoin-wrapped
      # derivation doesn't have — that breaks eval outright. Keeping
      # programs.steam.package as a plain steam.override chain (still
      # overridable) and routing the *launchers* (icewm menu, desktop entry)
      # through systemd-run instead sidesteps that.
      systemd.user.slices."steam-noswap".sliceConfig.MemorySwapMax = "0";

      programs.steam = lib.mkIf config.custom.steam.enable {
        enable = true;
        extraCompatPackages = [ pkgs.proton-ge-bin ];
        # These have to live in Steam's FHS, not just on PATH. A host
        # mangohud/gamescope is invisible to pressure-vessel otherwise, so
        # launch options like `mangohud %command%` / `gamescope -- %command%`
        # silently do nothing.
        extraPackages = with pkgs; [ gamescope mangohud ];
        remotePlay.openFirewall = true;
        localNetworkGameTransfers.openFirewall = true;
        # Steam Input on Wayland: translate X11 events to uinput so controllers
        # and Steam's overlay bindings actually reach games under Hyprland.
        extest.enable = true;
        protontricks.enable = true;
        # extraEnv always — scaling is independent of which GPU renders.
        # DRI_PRIME only when this host has a dGPU and displayGpu = "dgpu"
        # (see modules/platform.nix and docs/dgpu-steam-forcing.md).
        package = pkgs.steam.override {
          extraEnv = {
            # Framework 16 2560x1600 @ scale 1: Steam's UI is unreadably small
            # at 1.0. 1.25 is sharp enough not to look like a bitmap stretch.
            STEAM_FORCE_DESKTOPUI_SCALING = "1.25";
          } // lib.optionalAttrs (config.custom.platform.hasDgpu && config.custom.platform.displayGpu == "dgpu") {
            DRI_PRIME = "pci-" + lib.replaceStrings [ ":" "." ] [ "_" "_" ] config.custom.platform.dgpuPciId;
          };
        };
      };
      hardware.steam-hardware.enable = lib.mkIf config.custom.steam.enable true;
      # gamemode is owned by the active persona (on for the "gaming" persona).

      # ──────────────────────────────────────────────────────────────────────────
      # oligarchy-forge — sandboxed coding-agent runner
      # ──────────────────────────────────────────────────────────────────────────
      custom.oligarchyForge.enable = lib.mkDefault false;

      # ──────────────────────────────────────────────────────────────────────────
      # Terminus Developer Edition (local-only, references working trees)
      # ──────────────────────────────────────────────────────────────────────────
      custom.terminus-dev.enable = lib.mkDefault false;

      # ──────────────────────────────────────────────────────────────────────────
      # ArchibaldOS DSP Coprocessor VM
      # RT DSP guest with PREEMPT_RT kernel, CPU 0 isolated, NETJACK audio
      # ──────────────────────────────────────────────────────────────────────────
      custom.vm.dsp = {
        enable = lib.mkDefault false;
        # Do NOT autostart at boot, and this is now a policy choice rather than
        # a workaround. Starting the VM binds the second xHCI controller to
        # vfio-pci and hands it to the guest, so every audio interface on that
        # bus disappears from the host mid-session. That has to be deliberate.
        #
        # The old reason recorded here — "OVMF firmware not wired into the qemu
        # launch + no guest serial console" — was wrong on the first count and
        # is fixed on the second. OVMF was already wired in (`cfg.ovmf`, on by
        # default). What actually spun the isolated cores at 100% was the disk:
        # a hand-copied qcow2 with no EFI system partition, so OVMF found
        # nothing to boot and fell through to an endless PXE netboot loop. The
        # image is a derivation now (`nix build .#dsp-vm-qcow`, wired up in
        # flake.nix) and the console is a real socket, so `dsp-console` works.
        autoStart = false;
        name = "archibaldos-dsp";
        isolatedCores = [ 0 1 ];
        memoryMB = 2048;
        hugepages = 1024; # 2GB of 2MB hugepages (matches VM memory exactly; allocated dynamically, not at boot)
        cpuModel = "host";

        archibaldOS = {
          enable = true;
          netjack = {
            enable = true; # NETJACK routes processed audio back to host
            sourcePort = 4713;
            bufferSize = 32; # 32 frames @ 96kHz = 0.33ms period, 0.67ms buffer
            sampleRate = 96000;
            channels = 2;
          };
        };

        # VFIO passthrough of the second USB host controller (c7:00.3/4).
        # The VM gets direct hardware access to whatever audio interface is
        # plugged into that controller. The first controller (c5:00.3) stays
        # on the host for keyboard/mouse/BT.
        audioDevice = {
          enable = true;
          usbController = {
            enable = true;
            xhciUsb2PciId = "0000:c7:00.3"; # 1022:15C0 — empty, isolated IOMMU group 31
            xhciUsb3PciId = "0000:c7:00.4"; # 1022:15C1 — IOMMU group 32
            usb2VendorDevice = "1022:15C0";
            usb3VendorDevice = "1022:15C1";
          };
        };

        realtime = {
          enable = true;
          mlock = true;
          nice = -20;
        };

        ovmf = true;
        spice = false;
        vnc = false;
      };

      # Sunshine (Moonlight server for remote desktop/game streaming)
      # DISABLED — capSysAdmin was grabbing input devices and killing keyboard/BT
      # ──────────────────────────────────────────────────────────────────────────
      # services.sunshine = {
      #   enable = false;
      #   openFirewall = true;
      #   autoStart = false;
      #   capSysAdmin = true;  # Required for input capture
      # };

      # Use mkForce to resolve SSH askPassword conflicts (KDE-free askpass;
      # runs under XWayland, gnome-keyring provides the ssh-agent).
      programs.ssh.askPassword = lib.mkForce "${pkgs.x11_ssh_askpass}/libexec/x11-ssh-askpass";

      # ──────────────────────────────────────────────────────────────────────────
      # CPU security hardening (modules/cpu-security.nix)
      # ──────────────────────────────────────────────────────────────────────────
      # "hardened": forced mitigations, early microcode, MSR-write blocking, kernel-
      # image protection. SMT kept (DSP/build throughput) and the msr module left
      # loaded (undervolt/thermal tooling). vendor tracks custom.platform.cpu.
      # Verify: grep -r . /sys/devices/system/cpu/vulnerabilities/
      hardware.cpuSecurity = {
        enable = lib.mkDefault false;
        preset = "hardened";
      };

      # ──────────────────────────────────────────────────────────────────────────
      # Boot Configuration
      # ──────────────────────────────────────────────────────────────────────────
      boot = {
        # Cross-compilation support — riscv64 added for ArchibaldOS / StarFive JH7110 work
        binfmt.emulatedSystems = [ "aarch64-linux" "riscv64-linux" ];
        loader = {
          systemd-boot.enable = true;
          efi.canTouchEfiVariables = true;
        };

        # GPU (amdgpu.*), CPU pstate (amd_pstate) and Framework USB quirks now come
        # from modules/platform.nix per custom.platform.{gpu,cpu,framework}.
        kernelParams = [
          "pcie_aspm=off"
          "threadirqs" # threaded IRQs — lets rtkit prioritize audio IRQ handlers
        ];
        initrd.kernelModules = [ "thunderbolt" ];

        kernelModules = [
          "v4l2loopback"
          "thunderbolt"
          "xhci_pci"
        ];
        extraModulePackages = [ config.boot.kernelPackages.v4l2loopback ];

        extraModprobeConfig = ''
          options v4l2loopback devices=1 video_nr=10 card_label="Virtual Cam" exclusive_caps=1
          options usbcore autosuspend=-1
          # xhci_hcd.quirks intentionally unset — see modules/platform.nix
          # (forced TRUST_TX_LENGTH 0x40 correlated with HC death under dual USB audio)
        '';
      };

      # ──────────────────────────────────────────────────────────────────────────
      # Display & Desktop Environment
      # ──────────────────────────────────────────────────────────────────────────
      services.xserver = {
        enable = true; # Enable X11 for IceWM backup system

        # Keyboard configuration (matches Wayland setup)
        xkb = {
          layout = "us";
          variant = "";
          options = "caps:escape";
        };

        # Exclude unnecessary X11 packages
        excludePackages = [ pkgs.xterm ];

        # Window managers
        windowManager.icewm.enable = true;
      };

      # IceWM custom configuration
      environment.etc."icewm/preferences".text = ''
        # IceWM Configuration for Backup System
        # Optimized for minimal resource usage and stability

        # Focus and Behavior
        ClickToFocus=1
        FocusOnAppRaise=1
        RequestFocusOnAppRaise=1
        RaiseOnFocus=0
        RaiseOnClickClient=1
        PassFirstClickToClient=1

        # Task Bar
        ShowTaskBar=1
        TaskBarAtTop=0
        TaskBarKeepBelow=0
        TaskBarAutoHide=0
        TaskBarShowClock=1
        TaskBarShowAPMStatus=0
        TaskBarShowCPUStatus=1
        TaskBarShowMemStatus=1
        TaskBarShowNetStatus=1

        # Menu
        MenuMouseTracking=1
        ShowProgramsMenu=1
        ShowSettingsMenu=1
        ShowHelpMenu=1
        ShowRunMenu=1
        ShowLogoutMenu=1
        ShowLogoutSubMenu=1

        # Window Behavior
        SmartWindowPlacement=1
        AutoWindowArrange=1
        HideTitleBarWhenMaximized=0
        MenuMaximizedWidth=640
        Opacity=100

        # Performance
        GrabServerToAvoidRace=1
        DelayedFocusChange=1
        DelayedWindowMove=1

        # Workspaces
        WorkspaceNames=" 1 ", " 2 ", " 3 ", " 4 "
        LimitToWorkarea=1

        # Fonts
        TitleBarFontName="-*-sans-medium-r-*-*-12-*-*-*-*-*-*-*"
        MenuFontName="-*-sans-medium-r-*-*-12-*-*-*-*-*-*-*"
        StatusFontName="-*-sans-medium-r-*-*-12-*-*-*-*-*-*-*"
        QuickSwitchFontName="-*-sans-medium-r-*-*-12-*-*-*-*-*-*-*"
        NormalButtonFontName="-*-sans-medium-r-*-*-12-*-*-*-*-*-*-*"
        ActiveButtonFontName="-*-sans-bold-r-*-*-12-*-*-*-*-*-*-*"
        NormalTaskBarFontName="-*-sans-medium-r-*-*-12-*-*-*-*-*-*-*"
        ActiveTaskBarFontName="-*-sans-bold-r-*-*-12-*-*-*-*-*-*-*"
        MinimizedWindowFontName="-*-sans-medium-r-*-*-12-*-*-*-*-*-*-*"
        ListBoxFontName="-*-sans-medium-r-*-*-12-*-*-*-*-*-*-*"
        ToolTipFontName="-*-sans-medium-r-*-*-10-*-*-*-*-*-*-*"
        ClockFontName="-*-sans-bold-r-*-*-12-*-*-*-*-*-*-*"
        ApmFontName="-*-sans-medium-r-*-*-12-*-*-*-*-*-*-*"
        InputFontName="-*-monospace-medium-r-*-*-12-*-*-*-*-*-*-*"
        LabelFontName="-*-sans-bold-r-*-*-12-*-*-*-*-*-*-*"

        # Colors (fallback if theme doesn't provide)
        ColorNormalTitleBar="rgb:40/40/40"
        ColorActiveTitleBar="rgb:00/40/80"
        ColorNormalBorder="rgb:60/60/60"
        ColorActiveBorder="rgb:00/80/FF"

        # Paths
        DesktopBackgroundCenter=1
        DesktopBackgroundColor="rgb:20/20/20"
        DesktopBackgroundImage=""

        # Auto-restart if crashed (important for backup system)
        RestartOnFailure=1
      '';

      environment.etc."icewm/menu".text =
        let
          # See the "Gaming" section below for the steam-noswap.slice (swap
          # isolation) and the hardening property list (blast-radius
          # containment). Plain `systemd-run --user` (no --scope): a scope
          # just attaches an already-running process to a cgroup and can
          # only carry resource-control properties — systemd never forks/
          # execs it, so it can't apply the namespace/seccomp-backed
          # Protect*/NoNewPrivileges directives. A transient service does.
          # Blast-radius containment for a compromised game process. Deliberately
          # excludes RestrictNamespaces/SystemCallFilter (Steam's own Proton
          # sandbox, pressure-vessel, needs unshare/mount/pivot_root to build its
          # per-game container — blocking those breaks every Proton game),
          # MemoryDenyWriteExecute (breaks Wine's JIT and Unity/Mono), and
          # RestrictRealtime (GameMode may grant RT scheduling for frame pacing).
          steamHardeningProps = [
            "NoNewPrivileges=yes"
            "RestrictSUIDSGID=yes"
            "ProtectHostname=yes"
            "ProtectClock=yes"
            "ProtectKernelTunables=yes"
            "ProtectKernelLogs=yes"
            "ProtectKernelModules=yes"
            "ProtectControlGroups=yes"
            # ProtectHome is deliberately absent: Steam's library, shader
            # cache, and compat prefixes live under ~/.steam and
            # ~/.local/share/Steam. Hiding $HOME makes every launch look like
            # a first-run (or fail outright).
            "LockPersonality=yes"
          ];
          steamNoSwapLauncher = pkgs.writeShellScript "steam-noswap" ''
            exec ${pkgs.systemd}/bin/systemd-run --user --collect --slice=steam-noswap.slice \
              --description=steam-hardened \
              ${lib.concatMapStringsSep " " (p: "-p ${p}") steamHardeningProps} \
              -- /run/current-system/sw/bin/steam "$@"
          '';
        in
        ''
        # IceWM Menu Configuration
        # Basic applications menu for backup system

        prog Terminal terminal "/run/current-system/sw/bin/kitty"
        prog File Manager folder "/run/current-system/sw/bin/thunar"
        prog Web Browser browser "/run/current-system/sw/bin/firefox"
        prog Text Editor editor "/run/current-system/sw/bin/kate"
        prog System Monitor monitor "/run/current-system/sw/bin/htop"

        separator
        menu System {
          prog "Audio Settings" settings "/run/current-system/sw/bin/easyeffects"
          prog "Display Settings" display "/run/current-system/sw/bin/systemsettings5"
          prog "Network Settings" network "/run/current-system/sw/bin/nm-connection-editor"
          separator
          prog "NixOS Config" terminal "kitty -e sudo nano /etc/nixos/configuration.nix"
          prog "Rebuild System" terminal "kitty -e sudo nixos-rebuild switch"
          separator
          prog "Logout" logout "icewm-session --logout"
          prog "Reboot" reboot "systemctl reboot"
          prog "Shutdown" shutdown "systemctl poweroff"
        }

        separator
        menu Development {
          prog "Vim" terminal "kitty -e vim"
          prog "Git" terminal "kitty -e git"
          prog "Python" terminal "kitty -e python3"
        }

        separator
        menu Multimedia {
          prog "VLC" vlc "/run/current-system/sw/bin/vlc"
          prog "Audacity" audacity "/run/current-system/sw/bin/audacity"
          prog "OBS Studio" obs "/run/current-system/sw/bin/obs"
        }

        separator
        menu Graphics {
          prog "GIMP" gimp "/run/current-system/sw/bin/gimp"
          prog "Inkscape" inkscape "/run/current-system/sw/bin/inkscape"
          prog "Blender" blender "/run/current-system/sw/bin/blender"
        }

        separator
        menu Games {
          prog "Steam" steam "${steamNoSwapLauncher}"
          prog "Doom 3" dhewm3 "/run/current-system/sw/bin/dhewm3"
        }
      '';

      # KDE-free login: greetd + tuigreet (minimal Wayland TUI greeter, no Qt/Plasma).
      # tuigreet auto-lists the Hyprland wayland-session installed by
      # programs.hyprland.enable, so --remember-session selects Hyprland.
      services.greetd = {
        enable = true;
        # tuigreet is a TUI greeter; without this, greetd's unit gets none of
        # TTYPath/TTYReset/TTYVHangup/TTYVTDisallocate, so nothing on the
        # greetd side guarantees a clean VT regardless of what boot-intro left
        # behind on tty1. useTextGreeter wires all of that in for free.
        useTextGreeter = true;
        settings.default_session = {
          command = "${pkgs.tuigreet}/bin/tuigreet --time --remember --remember-session --asterisks --greeting 'OLIGARCHY // The War Machine'";
          user = "greeter";
        };
      };

      # Ensure greetd starts after the boot intro clears the framebuffer,
      # avoiding visual artifacts from mpv's GPU state lingering on tty1.
      #
      # restartIfChanged = false: greetd's ExecStart embeds ${pkgs.tuigreet}
      # and the global PATH, both of which change on nearly every rebuild.
      # nixos-rebuild switch restarts any changed unit by default, and
      # restarting greetd.service kills the live Hyprland session it spawned
      # (it's not a separately-managed logind session) — that's the crash
      # that was forcing a hard reboot after every switch. The new unit
      # definition still takes effect on the next login/boot; it just isn't
      # force-applied to an already-running session.
      systemd.services.greetd = {
        after = [ "boot-intro-player.service" ];
        wants = [ "boot-intro-player.service" ];
        restartIfChanged = false;
      };

      programs.hyprland = {
        enable = true;
        xwayland.enable = true;
        package = pkgs.hyprland;
      };
      systemd.defaultUnit = lib.mkForce "graphical.target";

      xdg.portal = {
        enable = true;
        extraPortals = [
          pkgs.xdg-desktop-portal-gtk
          pkgs.xdg-desktop-portal-hyprland
        ];
        config = {
          common.default = [ "hyprland" "gtk" ];
          hyprland.default = [ "hyprland" "gtk" ];
        };
      };

      # ──────────────────────────────────────────────────────────────────────────
      # OBS Studio
      # ──────────────────────────────────────────────────────────────────────────
      programs.obs-studio = {
        enable = true;
        enableVirtualCamera = true;
        plugins = with pkgs.obs-studio-plugins; [
          obs-pipewire-audio-capture
          obs-vaapi
          obs-vkcapture
          input-overlay
          advanced-scene-switcher
          obs-multi-rtmp
        ];
      };

      # ──────────────────────────────────────────────────────────────────────────
      # Networking (unchanged)
      # ──────────────────────────────────────────────────────────────────────────
      networking = {
        hostName = "nixos";
        networkmanager = {
          enable = true;
          wifi = {
            backend = "wpa_supplicant";
            powersave = false;
            scanRandMacAddress = true;
          };
          dns = "systemd-resolved";
          connectionConfig = {
            "connection.mdns" = 2;
            "connection.llmnr" = 2;
            "ipv6.ip6-privacy" = 2;
          };
          ethernet.macAddress = "preserve";
          logLevel = "INFO";
        };
        firewall = {
          enable = true;
          allowPing = true;
          # 4798x/4800x Sunshine ports removed — the service is disabled above;
          # re-add them alongside services.sunshine if it ever comes back.
          allowedTCPPorts = [ 22 443 ];
          allowedUDPPorts = [ 5353 ];
          # tailscale0 is NOT a trusted interface: every tailnet peer would
          # bypass the firewall to all ports. SSH is admitted per-interface
          # instead; the tailscale module handles reverse-path itself.
          interfaces."tailscale0".allowedTCPPorts = [ 22 ];
          logReversePathDrops = false;
          logRefusedConnections = false;
        };
        useDHCP = lib.mkDefault false;
        # NOTE: networking.wireless.enable removed — it ran a second, unmanaged
        # wpa_supplicant alongside NetworkManager's own (wifi.backend above),
        # which trips a NixOS assertion / causes the two to fight over the radio.
      };

      # SSH for local + Tailscale access (LAN already admits :22 in firewall).
      # Hardened settings (keys-only, AllowUsers, MaxAuthTries, fail2ban) are
      # owned by modules/security/hardening.nix (custom.security.hardening).
      services.openssh.enable = true;


      # Malware Shield (modules/security/malware-shield.nix) — monitor mode:
      # log + notify only. Review /var/lib/malware-shield/events.log for false
      # positives, then raise level to "quarantine". onAccess stays off (DSP
      # latency). Closure is scanned at build via `nix build .#malwareScan`.
      custom.malwareShield = {
        enable = lib.mkDefault false;
        level = "monitor";
        clamav = { enable = true; onAccess = false; };
        rootkit.enable = true;
        aide.enable = true;
        yara = {
          enable = true;
          # Setting excludePaths here replaces the module's default outright,
          # so both original entries are repeated below — dropping them would
          # silently re-enable the .claude/projects false positives the
          # default was written to prevent.
          excludePaths = [
            "/home/*/.claude/projects"
            "/home/*/.claude/file-history"
            # This repo's own EICAR pipeline-test fixture and the doc that
            # demonstrates it (modules/security/yara-rules/eicar.yar,
            # docs/security-hardening.md) both contain the literal EICAR
            # test string by design — the same structural false positive as
            # the two paths above, just from a second source the default
            # list didn't anticipate: a checkout of this repo living under a
            # scanned path.
            "/home/*/Documents/oligarchy2/Oligarchy/modules/security/yara-rules"
            "/home/*/Documents/oligarchy2/Oligarchy/docs/security-hardening.md"
          ];
        };
      };

      # sops-nix wiring (modules/secrets.nix). Safe with zero consumers:
      # declares only the age key location until a secret sub-option is on.
      # Pre-req: sudo age-keygen -o /var/lib/sops-nix/key.txt (see .sops.yaml).
      custom.secrets.enable = lib.mkDefault false;

      # Security hardening ladder (modules/security/hardening.nix):
      # SSH keys-only + fail2ban now; apparmor/auditd flip on after soak.
      custom.security.hardening = {
        enable = lib.mkDefault false;
        preset = "hardened";
        # Deferred to Phase 6 of the rollout — enable after a clean soak:
        apparmor = false;
        auditd = false;
      };

      # Strict egress filtering (modules/security/strict-egress.nix) —
      # back in DRY-RUN as of 2026-08-16.
      #
      # The "2026-08-09 audit soak" this was previously enforced on proved
      # nothing: the resolver pointed at a getent that does not exist, so the
      # dynamic allowlist was empty on every generation and the WOULDBLOCK log
      # was simply recording all public traffic. Enforcing on top of that
      # dropped everything off-LAN, and the failOpen path then flushed the
      # chain — which keeps `policy drop` — and black-holed egress outright.
      # Both bugs are fixed; re-enforce only after a soak on a populated set.
      networking.firewall.strictEgress = {
        enable = lib.mkDefault false;
        preset = "developer";
        recovery.dryRun = true;
        allow = {
          domains = [
            # Tailscale coordination. The DERP relay set is pulled live from
            # tailscaled via autoDetect.tailscale — it spans dozens of
            # unrelated /24s and cannot be usefully listed here.
            "controlplane.tailscale.com"
            "login.tailscale.com"
            # Claude Code / Anthropic API
            "api.anthropic.com"
            "claude.ai"
            "statsig.anthropic.com"
            # ollama (model pulls) + blipply-assistant (model downloads)
            "ollama.com"
            "registry.ollama.ai"
            "huggingface.co"
            # dcf-node-binary
            "api.demod.ltd"
            # Steam store/community/API/CDN — confirmed against live
            # WOULDBLOCK entries during the dry-run soak (store.steampowered.com
            # -> 23.0.194.117, api.steampowered.com -> 23.41.4.x,
            # cdn.steamstatic.com -> 199.232.211/215.52 all matched logged
            # would-blocks). Game-server traffic itself is IP-diverse by
            # design (arbitrary hosts, including Valve's SDR relays) and
            # can't be domain-allowlisted — see allow.ports below instead.
            "steampowered.com"
            "store.steampowered.com"
            "api.steampowered.com"
            "help.steampowered.com"
            "steamcommunity.com"
            "cdn.steamstatic.com"
            "community.akamai.steamstatic.com"
            "shared.akamai.steamstatic.com"
            "clientconfig.akamai.steamstatic.com"
            "steamcdn-a.akamaihd.net"
          ];
          # Steam Remote Play / Big Picture LAN device discovery (SSDP
          # NOTIFY). Multicast-scoped (TTL=1, never leaves the local
          # segment) so allowing the destination outright costs nothing.
          ips = [ "239.255.255.250/32" ];
          ports = [
            # WireGuard direct connections between tailscale peers
            { port = 41641; proto = "udp"; }
            # Steam/Source game-server + content ports (query, RCON,
            # in-game traffic, SDR). Destination IP is arbitrary — this is
            # the escape hatch strict-egress.nix documents for exactly that
            # case. Confirmed live: an established store.steampowered.com
            # session on TCP 27018 plus several logged UDP would-blocks on
            # 27055/27061/27079/27123 during the same soak.
            { port = 27000; to = 27100; proto = "tcp"; }
            { port = 27000; to = 27100; proto = "udp"; }
          ];
        };
      };

      # Tailscale mesh — join with: sudo tailscale up
      services.tailscale = {
        enable = true;
        openFirewall = true;
        useRoutingFeatures = "client";
      };

      services.resolved = {
        enable = true;
        dnssec = "allow-downgrade";
        domains = [ "~." ];
        fallbackDns = [ "1.1.1.1" "8.8.8.8" "2606:4700:4700::1111" "2001:4860:4860::8888" ];
        dnsovertls = "opportunistic";
      };

      systemd.services.systemd-networkd-wait-online.enable = lib.mkForce false;
      # Nothing enabled needs network-online at boot; on a laptop the link is
      # rarely up in time, so this only ever burned its full timeout and held
      # docker -> multi-user.target hostage for 30s every boot.
      systemd.services.NetworkManager-wait-online.enable = lib.mkForce false;

      # Shutdown timeout backstop. The stock 90s system / 90s user defaults let
      # a SINGLE process stuck in an uninterruptible kernel path cost 3m44s of
      # poweroff (hyprlock wedged in an amdgpu/TTM ioctl: 90s in hypridle's
      # stop, then 2min of user@1000 stop-sigterm, then 2min more after the
      # final SIGKILL). The fix for that specific process is elsewhere -- this
      # is the backstop, so the NEXT stuck process costs seconds instead.
      # Truncating a .swap stop is harmless at poweroff: the contents are
      # discarded either way. `systemd.extraConfig` is a removed option; the
      # system manager is configured via settings.Manager, the user manager
      # still via a lines-typed extraConfig.
      systemd.settings.Manager.DefaultTimeoutStopSec = "10s";
      systemd.user.extraConfig = "DefaultTimeoutStopSec=10s\n";

      # libvirt-guests ships TimeoutStopSec=0 -- literally infinity -- with
      # ON_SHUTDOWN=suspend and SHUTDOWN_TIMEOUT=300 per guest, serialised.
      # It is free today only because zero domains exist (it stops in 67ms);
      # defining one arms an unbounded wait. Bound both halves. This is a
      # timeout backstop, not a decision to stop using libvirt.
      virtualisation.libvirtd.shutdownTimeout = 30;
      # Guarded: the NixOS module only defines libvirt-guests when libvirtd is
      # enabled (it is here only because local.nix sets custom.vm.dsp.enable).
      # Unguarded this would synthesise a stub unit with no ExecStart on a
      # fresh clone.
      systemd.services.libvirt-guests.serviceConfig.TimeoutStopSec =
        lib.mkIf config.virtualisation.libvirtd.enable 60;

      # Astrill VPN egress list -> demod-blk-v4/v6. VPN detection, not threat
      # intel; the blocklists module below carries the actual threat feeds.
      services.demod-ip-blocker = {
        enable = lib.mkDefault false;
        updateInterval = "24h";
      };

      # Threat-intel blocklists (modules/security/ip-blocklists.nix) -> its own
      # olig-blk-v4/v6 sets, so the two never collide.
      #
      # Enforcing on both directions. That is safe here only because every feed
      # passes a preflight that rejects it wholesale if it carries protected
      # space, and because RFC1918/CGNAT/loopback, the live interface addresses,
      # the default gateway and every strict-egress-resolved IP are subtracted
      # unconditionally. FireHOL level1 is excluded for exactly that reason — it
      # bundles fullbogons and would blackhole the LAN and the Tailscale mesh.
      #
      # Escape hatch, no rebuild required: sudo oligarchy-blocklist panic
      networking.firewall.blocklists = {
        enable = lib.mkDefault false;
        feeds = [ "ipsum" "spamhaus-drop" "blocklist-de" "cins" ];
        ipsumLevel = 3;
        direction = "both";
        updateInterval = "6h";
      };

      # ──────────────────────────────────────────────────────────────────────────
      # Hardware (unchanged)
      # ──────────────────────────────────────────────────────────────────────────
      hardware = {
        bluetooth = {
          enable = true;
          powerOnBoot = true;
          settings = {
            General = {
              # Do NOT set Enable= — modern bluez rejects it ("Unknown key Enable")
              Experimental = true;
              FastConnectable = true;
              JustWorksRepairing = "always";
              MultiProfile = "multiple";
              KernelExperimental = true;
            };
            Policy = {
              AutoEnable = true;
            };
          };
        };

        enableRedistributableFirmware = true;

        graphics = {
          enable = true;
          enable32Bit = true;
          # Vendor-neutral VAAPI/VDPAU bridges. GPU-specific userspace (ROCm for
          # AMD, intel-media-driver for Intel) is added by modules/platform.nix.
          extraPackages = with pkgs; [
            libva-vdpau-driver
            libvdpau-va-gl
          ];
        };
      };

      services.blueman.enable = true;

      # ──────────────────────────────────────────────────────────────────────────
      # Locale & Time (unchanged)
      # ──────────────────────────────────────────────────────────────────────────
      time.timeZone = "America/Los_Angeles";
      i18n = {
        defaultLocale = "en_US.UTF-8";
        extraLocaleSettings = {
          LC_ADDRESS = "en_US.UTF-8";
          LC_IDENTIFICATION = "en_US.UTF-8";
          LC_MEASUREMENT = "en_US.UTF-8";
          LC_MONETARY = "en_US.UTF-8";
          LC_NAME = "en_US.UTF-8";
          LC_NUMERIC = "en_US.UTF-8";
          LC_PAPER = "en_US.UTF-8";
          LC_TELEPHONE = "en_US.UTF-8";
          LC_TIME = "en_US.UTF-8";
        };
      };

      # ──────────────────────────────────────────────────────────────────────────
      # System Services (unchanged)
      # ──────────────────────────────────────────────────────────────────────────
      services = {
        dbus = {
          enable = true;
          packages = with pkgs; [ dconf gcr ];
        };

        libinput.enable = true;
        acpid.enable = true;
        udisks2.enable = true;
        gvfs.enable = true;
        fwupd.enable = true;
        fprintd.enable = true;

        printing = {
          enable = true;
          drivers = with pkgs; [
            gutenprint
            gutenprintBin
            hplip
            brlaser
          ];
        };

        avahi = {
          enable = true;
          nssmdns4 = true;
          nssmdns6 = true;
          openFirewall = true;
          publish = {
            enable = true;
            addresses = true; # keep: printers/peers resolve this host via mDNS
            workstation = false; # don't advertise host metadata on every LAN
            userServices = false;
          };
        };

        power-profiles-daemon.enable = true;
        tlp.enable = lib.mkForce false;
        # thermald removed: it is Intel-only and exits immediately on AMD silicon.
        # power-profiles-daemon + amd_pstate handle thermals on the Framework 16.

        upower = {
          enable = true;
          percentageLow = 20;
          percentageCritical = 10;
          percentageAction = 5;
          # swapDevices exist now (see the Memory Configuration block above)
          # but boot.resumeDevice is still unset, so Hibernate/HybridSleep
          # still can't resume — power off cleanly at critical battery
          # instead. Switch back to "Hibernate" only after filling in
          # resumeDevice + resume_offset (see the hibernate block above).
          criticalPowerAction = "PowerOff";
        };

        hardware.bolt.enable = true;

        geoclue2 = {
          enable = true;
          enableWifi = true;
        };

        udev.extraRules = ''
          # PCI XHCI host controllers (class 0x0c0330) must stay awake.
          # Device-level USB autosuspend alone is NOT enough — parent D3hot
          # suspend resets the whole tree (Framework kbd + MediaTek BT).
          ACTION=="add", SUBSYSTEM=="pci", ATTR{class}=="0x0c0330", ATTR{power/control}="on"

          # USB devices only — never interfaces (they have no power/* attrs;
          # matching interfaces spams "Could not chase sysfs attribute").
          ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{power/control}="on"
          ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{power/autosuspend}="-1"
          ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{power/autosuspend_delay_ms}="-1"

          # USB hubs (device class 09)
          ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{bDeviceClass}=="09", ATTR{power/control}="on"

          # Framework keyboard module + any Framework USB device (vendor 32ac)
          ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="32ac", ATTR{power/control}="on"
          ACTION=="add", SUBSYSTEM=="usb", ENV{DEVTYPE}=="usb_device", ATTR{idVendor}=="32ac", ATTR{power/autosuspend}="-1"

          # Thunderbolt authorize (Framework expansion bay)
          ACTION=="add", SUBSYSTEM=="thunderbolt", ATTR{authorized}=="0", ATTR{authorized}="1"
        '';

        logind.settings.Login = {
          HandleLidSwitch = "ignore";
          HandleLidSwitchExternalPower = "ignore";
          HandleLidSwitchDocked = "ignore";
          HandlePowerKey = "poweroff";
          HandleSuspendKey = "suspend";
          IdleAction = "ignore";
          RuntimeDirectorySize = "50%";
        };
      };

      # ──────────────────────────────────────────────────────────────────────────
      # Security (unchanged)
      # ──────────────────────────────────────────────────────────────────────────
      security = {
        rtkit.enable = true;
        polkit.enable = true;

        pam.services = {
          login = { fprintAuth = true; enableGnomeKeyring = true; };
          sudo = { fprintAuth = true; };
          greetd = { enableGnomeKeyring = true; };
          # fprintAuth is OFF here on purpose. pam_fprintd lands FIRST and
          # `sufficient` in /etc/pam.d/hyprlock, but no fingers are enrolled on
          # the Goodix sensor -- so every single lock D-Bus-activated fprintd
          # and sat on it for ~30s, buying nothing: hyprlock's own
          # auth:fingerprint:enabled defaults off, so the reader never drove
          # the UI anyway. To actually use it, flip this back to true AND set
          # auth:fingerprint:enabled in home/apps/hyprlock.nix -- both, or it
          # regresses to the same dead leg.
          hyprlock = { fprintAuth = false; enableGnomeKeyring = true; };
        };



        pam.loginLimits = [
          { domain = "@audio"; type = "-"; item = "rtprio"; value = "99"; }
          { domain = "@audio"; type = "-"; item = "memlock"; value = "unlimited"; }
          { domain = "@audio"; type = "-"; item = "nice"; value = "-19"; }
        ];

        sudo = {
          enable = true;
          wheelNeedsPassword = true;
          extraConfig = ''
            Defaults env_keep += "EDITOR VISUAL"
            Defaults env_keep += "NIX_PATH"
            Defaults env_keep += "SSH_AUTH_SOCK"
            Defaults timestamp_timeout=5
          '';
        };
      };

      services.gnome.gnome-keyring.enable = true;
      programs.seahorse.enable = true;

      # Applying pending firmware on every boot cost ~3.8s; the fwupd-refresh
      # timer and manual `fwupdmgr update` still cover updates.
      environment.etc."fwupd/fwupd.conf".text = lib.mkForce ''
        [fwupd]
        UpdateOnBoot=false
      '';

      # ──────────────────────────────────────────────────────────────────────────
      # Virtualization (unchanged)
      # ──────────────────────────────────────────────────────────────────────────
      # Rootless Docker: the daemon runs as asher, so membership in the
      # root-equivalent "docker" group is no longer needed (or granted).
      # `docker compose` works unchanged via DOCKER_HOST (setSocketVariable).
      # Note: re-enabling custom.dcfIdentity/dcfCommunityNode requires the
      # rootful daemon (oci-containers backend) — guarded by assertions below.
      virtualisation.docker.rootless = {
        enable = true;
        setSocketVariable = true;
        # Default docker (docker_28) is flagged insecure/unmaintained since
        # Nov 2025; pin the maintained release rather than allow an insecure pkg.
        package = pkgs.docker_29;
        daemon.settings = {
          dns = [ "1.1.1.1" "8.8.8.8" ];
          log-driver = "json-file";
          log-opts = {
            max-size = "10m";
            max-file = "3";
          };
        };
      };

      # oci-containers (DCF stack) drive the ROOTFUL daemon; fail loudly if
      # they are re-enabled without bringing virtualisation.docker back.
      assertions = [
        {
          assertion = config.custom.dcfIdentity.enable -> config.virtualisation.docker.enable;
          message = "custom.dcfIdentity uses oci-containers (rootful docker). Re-enable virtualisation.docker or migrate the container to rootless first.";
        }
        {
          assertion = config.custom.dcfCommunityNode.enable -> config.virtualisation.docker.enable;
          message = "custom.dcfCommunityNode uses oci-containers (rootful docker). Re-enable virtualisation.docker or migrate the container to rootless first.";
        }
      ];

      programs.wireshark.enable = true;

      # ──────────────────────────────────────────────────────────────────────────
      # Users (primary account name comes from custom.user.name, modules/user.nix)
      # ──────────────────────────────────────────────────────────────────────────
      users.users.${config.custom.user.name} = {
        isNormalUser = true;
        description = config.custom.user.name;
        # No "input" — compositor routes HID for normal desktop use.
        # Raw-evdev daemons (blipply service user) keep their own group membership.
        # "docker" removed (root-equivalent; docker is rootless now).
        # "render" added: rootless ollama container needs /dev/kfd for ROCm.
        extraGroups = [ "networkmanager" "wheel" "wireshark" "disk" "video" "audio" "render" ];
        shell = pkgs.bash;

        # Keys that may SSH in (merged with ~/.ssh/authorized_keys). Declared
        # here (not just via a separate assignment) because Nix disallows two
        # dynamic-attrpath (`${...}`) definitions against the same computed
        # key in one config block, unlike static nested attrpaths. Edit the
        # list in modules/user.nix, not here. The hardening module's
        # lockout-guard assertion verifies a key exists before it disables
        # SSH password authentication.
        openssh.authorizedKeys.keys = config.custom.user.sshAuthorizedKeys;
      };

      # XHCI recover CLI — ssh <custom.user.name>@<tailscale-ip> 'sudo xhci-recover'
      # after "HC died" on AMD 0000:c5:00.3 (WiFi path survives; USB NIC does not).
      # Binary is on PATH via environment.systemPackages below (shared derivation).
      # List both the nix-store path and the /run/current-system symlink so
      # `sudo xhci-recover` (PATH) and an explicit store path both match NOPASSWD.
      security.sudo.extraRules = [
        {
          users = [ config.custom.user.name ];
          commands = [
            {
              command = "${xhci-recover}/bin/xhci-recover";
              options = [ "NOPASSWD" ];
            }
            {
              command = "/run/current-system/sw/bin/xhci-recover";
              options = [ "NOPASSWD" ];
            }
          ];
        }
      ];

      # Clear sticky Bluetooth soft-blocks left by prior XHCI runtime-suspend
      # cascades. Runtime recurrence is fixed by the PCI XHCI udev rule above;
      # this purges saved state on switch/boot and unblocks after bluetooth.service.
      system.activationScripts.unblockBluetoothRfkill.text = ''
        if [ -d /var/lib/systemd/rfkill ]; then
          for f in /var/lib/systemd/rfkill/*bluetooth*; do
            [ -f "$f" ] || continue
            echo 0 > "$f" || true
          done
        fi
      '';

      # systemd-rfkill can restore SoftBlock=1 from saved state *after* activation
      # and racing this service; delay + rewrite files + unblock.
      systemd.services.unblock-bluetooth = {
        description = "Unblock Bluetooth rfkill after sticky soft-blocks";
        after = [ "bluetooth.service" "systemd-rfkill.service" "multi-user.target" ];
        wants = [ "bluetooth.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStartPre = "${pkgs.coreutils}/bin/sleep 2";
          ExecStart = pkgs.writeShellScript "unblock-bt" ''
            set -e
            if [ -d /var/lib/systemd/rfkill ]; then
              for f in /var/lib/systemd/rfkill/*bluetooth*; do
                [ -f "$f" ] || continue
                echo 0 > "$f" || true
              done
            fi
            ${pkgs.util-linux}/bin/rfkill unblock bluetooth || true
          '';
        };
      };

      # ──────────────────────────────────────────────────────────────────────────
      # System Maintenance (unchanged)
      # ──────────────────────────────────────────────────────────────────────────
      systemd.timers.nix-gc-generations = {
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnCalendar = "weekly";
          Persistent = true;
        };
      };
      systemd.services.nix-gc-generations = {
        script = ''
          generations_to_delete=$(${pkgs.nix}/bin/nix-env -p /nix/var/nix/profiles/system --list-generations | \
            ${pkgs.gawk}/bin/awk '{print $1}' | \
            ${pkgs.coreutils}/bin/head -n -5 | \
            ${pkgs.coreutils}/bin/tr '\n' ' ')

          if [ -n "$generations_to_delete" ]
          then
            ${pkgs.nix}/bin/nix-env -p /nix/var/nix/profiles/system --delete-generations $generations_to_delete
          fi

          ${pkgs.nix}/bin/nix-collect-garbage
        '';
        serviceConfig.Type = "oneshot";
      };

      # ──────────────────────────────────────────────────────────────────────────
      # System Packages (removed legacy audio tools)
      # ──────────────────────────────────────────────────────────────────────────
      environment.systemPackages = with pkgs; [
        # ── Essentials: needed to actually use/debug this desktop on this
        # hardware, regardless of who built it or why. Everything personal
        # (dev toolchain, DAWs, SDR, games, creative apps, browsers/office,
        # Android tooling) lives in the enablePersonalApps block below.
        vim
        git
        git-lfs
        gh
        htop
        nvme-cli
        lm_sensors
        dmidecode
        util-linux
        gparted
        usbutils
        # dual-HS bus recover (PCI rebind 0000:c5:00.3); sudo NOPASSWD for asher
        xhci-recover

        wireshark
        tcpdump
        nmap
        netcat
        ncdu
        inetutils
        dnsutils
        whois
        iperf3
        mtr
        ethtool
        wavemon
        networkmanagerapplet

        vulkan-tools
        vulkan-loader
        vulkan-validation-layers
        libva-utils

        blueberry
        font-awesome
        fastfetch
        gnugrep
        kitty
        wofi
        waybar
        hyprpaper
        brightnessctl
        zip
        unzip
        xarchiver

        gvfs
        udiskie
        polkit_gnome
        framework-tool
        blucontrol

        wl-clipboard
        grim
        slurp
        v4l-utils
        cliphist
        hyprpicker
        wlogout
        playerctl
        jq
        hyprlock
        hypridle
        libnotify
        swappy
        hyprshot
        satty
        gpu-screen-recorder
        gpu-screen-recorder-gtk

        # IceWM backup system
        icewm
      ] ++ lib.optionals config.custom.desktopFeatures.enablePersonalApps [
        # `docker` CLI is provided on PATH by virtualisation.docker (docker_29);
        # listing pkgs.docker here pulled the insecure docker_28 default.
        android-studio
        android-tools
        jdk17
        (androidenv.composeAndroidPackages {
          platformVersions = [ "34" ];
          buildToolsVersions = [ "34.0.0" ];
          includeEmulator = false;
          includeSources = false;
        }).androidsdk

        s-tui
        stress

        (python3.withPackages (ps: with ps; [
          pip
          virtualenv
          cryptography
          pycryptodome
          grpcio
          grpcio-tools
          protobuf
          numpy
          matplotlib
          python-snappy
          tkinter
        ]))

        cmake
        gcc
        gnumake
        ninja
        rustc
        cargo
        go
        openssl
        gnutls
        pkgconf
        snappy
        protobuf

        ardour
        audacity
        ffmpeg-full
        libpulseaudio
        musescore
        easyeffects
        pkgsi686Linux.libpulseaudio
        guitarix
        faust
        faustlive
        qpwgraph
        rnnoise-plugin

        qemu
        virt-manager
        docker-compose
        docker-buildx

        dhewm3
        darkradiant
        zandronum
        shipwright
        beyond-all-reason

        inputs.minecraft.packages.${pkgs.stdenv.hostPlatform.system}.default

        vlc
        pandoc
        floorp-bin
        thunderbird
        brave
        vscode

        legcord
        obsidian

        gimp
        kdePackages.kdenlive
        inkscape
        blender
        openscad
        libreoffice
        krita
        synfigstudio

        mininet

        rtl-sdr
        gnuradio
        gqrx
        soapysdr
        cubicsdr

        qjackctl
        adlplug
        chuck
        csound

        ghc

        ollama
        opencode # open-webui alpaca aichat aider-chat  # disabled: open-webui npm build OOMs

        #(perl.withPackages (ps: with ps; [
        #  JSON GetoptLong CursesUI ModulePluggable Appcpanminus
        #]))

        # sbcl.withPackages (ps: with ps; [
        #   cffi cl-ppcre cl-json cl-csv usocket bordeaux-threads log4cl
        #   trivial-backtrace cl-store hunchensocket fiveam cl-dot cserial-port
        # ])

        libserialport
        can-utils
        lksctp-tools
        cjson
        ncurses
        libuuid
        carla
        # kicad graphviz mako openscad freecad strawberry  # disabled: kicad-packages3d OOMs disk

        unetbootin
        popsicle
        gnome-disk-utility
      ] ++ lib.optionals config.custom.steam.enable [
        steam
        steam-run
        linuxConsoleTools
        lutris
        wineWowPackages.stable
      ];

      # ──────────────────────────────────────────────────────────────────────────
      # Environment (Wayland-optimized variables)
      # ──────────────────────────────────────────────────────────────────────────
      environment.sessionVariables = {
        # Core variables that work in both environments
        OBS_USE_EGL = "1";
        QT_QPA_PLATFORMTHEME = "kde";

        # Wayland-preferred with X11 fallback. The old hard "wayland" values
        # sabotaged the IceWM backup session: Qt/GTK/SDL apps refused to start
        # under X11 because no Wayland display existed. Fallback lists let each
        # toolkit pick whichever display server is actually running.
        QT_QPA_PLATFORM = "wayland;xcb";
        NIXOS_OZONE_WL = "1";
        GDK_BACKEND = "wayland,x11,*";
        SDL_VIDEODRIVER = "wayland,x11";
        MOZ_ENABLE_WAYLAND = "1";
      };

      system.stateVersion = "25.11";
    };
}

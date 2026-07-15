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
    ./modules/terminus-dev.nix
  ]
  # Optional local overrides written by the control center (kernel/platform
  # selection). Must be git-tracked for the flake to see it; the UI runs `git add`.
  ++ lib.optional (builtins.pathExists ./oligarchy-local.nix) ./oligarchy-local.nix;

  options = {
    custom.steam.enable = lib.mkEnableOption "Steam and gaming support";
  };

  config = let
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
  in {
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
    enable = true;

    # Theme selection — pick your DeMoD palette
    # Options: classic, amber, cyan, magenta, red, white, oligarchy, archibald
    theme = "oligarchy";

    # Branding
    titleText = "Initiating Oligarchy";
    bottomText = "A NixOS distro";

    # Optional: Your logo (PNG or animated GIF)
    # Re-enable once the asset is added & git-tracked (assets/modretro.png is
    # absent from the repo, so referencing it fails pure flake eval).
    # logoImage = ./assets/modretro.png;
    # logoScale = 0.5;

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
    resolution = "2560x1600";  # Match your Framework 16 display
    waveformOpacity = 0.7;
    fadeDuration = 2.0;
  };


    # ──────────────────────────────────────────────────────────────────────────
    # DCF Stack Configuration
    # ──────────────────────────────────────────────────────────────────────────

    # Community Node - Set your actual node ID
    custom.dcfCommunityNode = {
      enable = false;
      nodeId = "alh477";  # Your actual node ID
      openFirewall = true;
    };
    # Identity Service - Enable for production
    custom.dcfIdentity = {
      enable = false;
      domain = "dcf.demod.ltd";
      port = 4000;
      dataDir = "/var/lib/demod-identity";
      secretsFile = "/etc/nixos/secrets/dcf-id.env";
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
    # removed. The secure, local, read-only Oligarchy MCP (modules/oligarchy-mcp.nix)
    # is the agentic action surface; Blipply consumes it via stdio.
    custom.oligarchyMcp.enable = true;

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
    # swapDevices = [
    #   { device = "/swapfile";
    #     size = 32768; }  # 32 GiB — disabled to free disk space
    # ];

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
    warnings = lib.optional (config.boot.resumeDevice == "")
      "Oligarchy: upower criticalPowerAction is Hibernate but boot.resumeDevice is unset — hibernation cannot resume. See the hibernate block near swapDevices in configuration.nix.";

    boot.kernel.sysctl = {
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
    custom.steam.enable = true;
    programs.steam = lib.mkIf config.custom.steam.enable {
      enable = true;
      extraCompatPackages = [ pkgs.proton-ge-bin ];
    };
    hardware.steam-hardware.enable = lib.mkIf config.custom.steam.enable true;
    # gamemode is owned by the active persona (on for the "gaming" persona).

    # ──────────────────────────────────────────────────────────────────────────
    # Terminus Developer Edition (local-only, references working trees)
    # ──────────────────────────────────────────────────────────────────────────
    custom.terminus-dev.enable = true;

    # ──────────────────────────────────────────────────────────────────────────
    # ArchibaldOS DSP Coprocessor VM
    # RT DSP guest with PREEMPT_RT kernel, CPU 0 isolated, NETJACK audio
    # ──────────────────────────────────────────────────────────────────────────
    custom.vm.dsp = {
      enable = true;
      name = "archibaldos-dsp";
      isolatedCores = [ 0 ];
      memoryMB = 2048;
      hugepages = 1024;  # 2GB of 2MB hugepages
      cpuModel = "host";

      archibaldOS = {
        enable = true;
        netjack = {
          enable = true;       # NETJACK routes processed audio back to host
          sourcePort = 4713;
          bufferSize = 32;     # 32 frames @ 96kHz = 0.33ms period, 0.67ms buffer
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
          xhciUsb2PciId = "0000:c7:00.3";  # 1022:15C0 — empty, isolated IOMMU group 31
          xhciUsb3PciId = "0000:c7:00.4";  # 1022:15C1 — IOMMU group 32
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

    # Use mkForce to resolve SSH askPassword conflicts (prefer KDE solution)
    programs.ssh.askPassword = lib.mkForce "${pkgs.kdePackages.ksshaskpass}/bin/ksshaskpass";

    # ──────────────────────────────────────────────────────────────────────────
    # CPU security hardening (modules/cpu-security.nix)
    # ──────────────────────────────────────────────────────────────────────────
    # "hardened": forced mitigations, early microcode, MSR-write blocking, kernel-
    # image protection. SMT kept (DSP/build throughput) and the msr module left
    # loaded (undervolt/thermal tooling). vendor tracks custom.platform.cpu.
    # Verify: grep -r . /sys/devices/system/cpu/vulnerabilities/
    hardware.cpuSecurity = {
      enable = true;
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
        "threadirqs"  # threaded IRQs — lets rtkit prioritize audio IRQ handlers
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
      enable = true;  # Enable X11 for IceWM backup system

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

    environment.etc."icewm/menu".text = ''
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
        prog "Steam" steam "/run/current-system/sw/bin/steam"
        prog "Doom 3" dhewm3 "/run/current-system/sw/bin/dhewm3"
      }
    '';

    services.displayManager = {
      sddm = {
        enable = true;
        wayland.enable = true;
      };
      defaultSession = "plasma";  # Keep Plasma (Wayland) as default
    };

    services.desktopManager.plasma6.enable = true;
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
        pkgs.kdePackages.xdg-desktop-portal-kde
      ];
      config = {
        common.default = [ "kde" "hyprland" "gtk" ];
        hyprland.default = [ "hyprland" "gtk" ];
        kde.default = [ "kde" "gtk" ];
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
          scanRandMacAddress = false;
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
        allowedTCPPorts = [ 22 443 47984 47989 47990 48010 ];
        allowedUDPPorts = [ 5353 47998 47999 48000 48002 48010 ];
        # tailscale0 is the mesh interface; trust so node-to-node SSH works
        # without fighting reverse-path on the CGNAT range.
        trustedInterfaces = [ "docker0" "br-+" "tailscale0" ];
        logReversePathDrops = false;
        logRefusedConnections = false;
      };
      useDHCP = lib.mkDefault false;
      # NOTE: networking.wireless.enable removed — it ran a second, unmanaged
      # wpa_supplicant alongside NetworkManager's own (wifi.backend above),
      # which trips a NixOS assertion / causes the two to fight over the radio.
    };

    # SSH for local + Tailscale access (LAN already admits :22 in firewall).
    services.openssh = {
      enable = true;
      settings = {
        PasswordAuthentication = true;
        KbdInteractiveAuthentication = false;
        PermitRootLogin = "prohibit-password";
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

    services.demod-ip-blocker = {
      enable = true;
      updateInterval = "24h";
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
          addresses = true;
          workstation = true;
          userServices = true;
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
        criticalPowerAction = "Hibernate";
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
        sddm = { enableGnomeKeyring = true; };
        hyprlock = { fprintAuth = true; enableGnomeKeyring = true; };
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
          Defaults timestamp_timeout=30
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
    virtualisation.docker = {
      enable = true;
      # Default docker (docker_28) is flagged insecure/unmaintained since
      # Nov 2025; pin the maintained release rather than allow an insecure pkg.
      package = pkgs.docker_29;
      # Socket-activated: dockerd (and its restart-policy containers) start on
      # first use instead of the boot critical path.
      enableOnBoot = false;
      storageDriver = "overlay2";
      autoPrune = {
        enable = true;
        dates = "weekly";
        flags = [ "--all" "--volumes" ];
      };
      daemon.settings = {
        dns = [ "1.1.1.1" "8.8.8.8" ];
        default-address-pools = [
          { base = "172.17.0.0/16"; size = 24; }
          { base = "172.18.0.0/16"; size = 24; }
        ];
        live-restore = true;
        log-driver = "json-file";
        log-opts = {
          max-size = "10m";
          max-file = "3";
        };
      };
      rootless.enable = false;
    };

    systemd.sockets.docker.wantedBy = [ "sockets.target" ];

    programs.wireshark.enable = true;

    # ──────────────────────────────────────────────────────────────────────────
    # Users (unchanged)
    # ──────────────────────────────────────────────────────────────────────────
    users.users.asher = {
      isNormalUser = true;
      description = "Asher";
      # No "input" — compositor routes HID for normal desktop use.
      # Raw-evdev daemons (blipply service user) keep their own group membership.
      extraGroups = [ "networkmanager" "wheel" "docker" "wireshark" "disk" "video" "audio" ];
      shell = pkgs.bash;
    };

    # XHCI recover CLI — ssh asher@<tailscale-ip> 'sudo xhci-recover'
    # after "HC died" on AMD 0000:c5:00.3 (WiFi path survives; USB NIC does not).
    # Binary is on PATH via environment.systemPackages below (shared derivation).
    # List both the nix-store path and the /run/current-system symlink so
    # `sudo xhci-recover` (PATH) and an explicit store path both match NOPASSWD.
    security.sudo.extraRules = [
      {
        users = [ "asher" ];
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
      # `docker` CLI is provided on PATH by virtualisation.docker (docker_29);
      # listing pkgs.docker here pulled the insecure docker_28 default.
      android-studio android-tools jdk17
      (androidenv.composeAndroidPackages {
        platformVersions = [ "34" ];
        buildToolsVersions = [ "34.0.0" ];
        includeEmulator = false;
        includeSources = false;
      }).androidsdk
      vim git git-lfs gh htop nvme-cli lm_sensors s-tui stress
      dmidecode util-linux gparted usbutils
      # dual-HS bus recover (PCI rebind 0000:c5:00.3); sudo NOPASSWD for asher
      xhci-recover

      (python3.withPackages (ps: with ps; [
        pip virtualenv cryptography pycryptodome grpcio grpcio-tools
        protobuf numpy matplotlib python-snappy tkinter
      ]))

      wireshark tcpdump nmap netcat ncdu
      inetutils dnsutils whois iperf3 mtr ethtool wavemon networkmanagerapplet

      cmake gcc gnumake ninja rustc cargo go openssl gnutls pkgconf snappy protobuf

      ardour audacity ffmpeg-full libpulseaudio musescore easyeffects
      pkgsi686Linux.libpulseaudio guitarix faust faustlive qpwgraph rnnoise-plugin

      qemu virt-manager docker-compose docker-buildx

      vulkan-tools vulkan-loader vulkan-validation-layers libva-utils

      dhewm3 darkradiant zandronum shipwright beyond-all-reason

      inputs.minecraft.packages.${pkgs.stdenv.hostPlatform.system}.default

      vlc pandoc kdePackages.okular floorp-bin thunderbird
      kdePackages.xdg-desktop-portal-kde brave vscode

      blueberry legcord font-awesome fastfetch gnugrep kitty wofi waybar
      hyprpaper brightnessctl zip unzip obsidian

      gimp kdePackages.kdenlive inkscape blender libreoffice krita synfigstudio

      gvfs udiskie polkit_gnome framework-tool blucontrol

      wl-clipboard grim slurp v4l-utils cliphist hyprpicker wlogout playerctl jq
      hyprlock hypridle libnotify swappy hyprshot satty kdePackages.spectacle
      gpu-screen-recorder gpu-screen-recorder-gtk

      mininet

      rtl-sdr gnuradio gqrx soapysdr cubicsdr

      qjackctl adlplug chuck csound

      ghc

      ollama opencode # open-webui alpaca aichat aider-chat  # disabled: open-webui npm build OOMs

      # IceWM backup system
      icewm

      #(perl.withPackages (ps: with ps; [
      #  JSON GetoptLong CursesUI ModulePluggable Appcpanminus
      #]))

      # sbcl.withPackages (ps: with ps; [
      #   cffi cl-ppcre cl-json cl-csv usocket bordeaux-threads log4cl
      #   trivial-backtrace cl-store hunchensocket fiveam cl-dot cserial-port
      # ])

      libserialport can-utils lksctp-tools cjson ncurses libuuid
      carla
      # kicad graphviz mako openscad freecad strawberry  # disabled: kicad-packages3d OOMs disk

      unetbootin popsicle gnome-disk-utility
    ] ++ lib.optionals config.custom.steam.enable [
      steam steam-run linuxConsoleTools lutris wineWowPackages.stable
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

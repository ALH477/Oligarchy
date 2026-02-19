{ config, pkgs, lib, inputs, nixpkgs-unstable, ... }:

{
  # ============================================================================
  # NixOS Production Configuration — Framework 16 AMD
  # ============================================================================

  imports = [
    ./modules/audio.nix
	./modules/boot-intro.nix
    ./modules/dcf-community-node.nix
    ./modules/dcf-identity.nix
    ./modules/dcf-tray.nix
  ];

  options = {
    custom.steam.enable = lib.mkEnableOption "Steam and gaming support";
  };

  config = {
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
     logoImage = ./assets/modretro.png;
     logoScale = 0.5;

    # Audio source — MIDI gets synthesized, audio files normalized
    # soundFile = ./assets/boot-chime.mid;
    # Or use a wav/mp3/flac:
     soundFile = ./assets/modretro.wav;
	volume = 40;
    # Optional: Background video (loops behind waveform)
     backgroundVideo = ./assets/modretro.mp4;

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

    # ──────────────────────────────────────────────────────────────────────────
    # Local AI Stack (Ollama)
    # ──────────────────────────────────────────────────────────────────────────
    services.ollamaAgentic = {
      enable = true;
      preset = "pewdiepie";  # High-performance preset
      acceleration = "rocm";
      advanced.rocm.gfxVersionOverride = "11.0.2";
      # RDNA3
    };

    # ──────────────────────────────────────────────────────────────────────────
    # OpenClaw AI Assistant Gateway
    # ──────────────────────────────────────────────────────────────────────────
    services.openclaw-agent = {
      enable = true;
      lanAccess = true;  # Allow LAN access without opening firewall port
      plugins = [
        { source = "github:openclaw/summarize"; }
        { source = "github:openclaw/oracle"; }
        { source = "github:openclaw/peekaboo"; }
      ];
    };

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
      extraConfig.pipewire."20-low-latency" = {
        "context.properties" = {
          "default.clock.rate" = 48000;
          "default.clock.quantum" = 256;
          "default.clock.min-quantum" = 256;
          "default.clock.max-quantum" = 512;
        };
      };

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
    swapDevices = [
      { device = "/swapfile";
        size = 32680; }  # 32 GiB
    ];
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
    programs.gamemode.enable = lib.mkIf config.custom.steam.enable true;
    
    # Use mkForce to resolve SSH askPassword conflicts (prefer KDE solution)
    programs.ssh.askPassword = lib.mkForce "${pkgs.kdePackages.ksshaskpass}/bin/ksshaskpass";

    # ──────────────────────────────────────────────────────────────────────────
    # Boot Configuration
    # ──────────────────────────────────────────────────────────────────────────
    boot = {
      # Cross-compilation support
      binfmt.emulatedSystems = [ "aarch64-linux" ];
      loader = {
        systemd-boot.enable = true;
        efi.canTouchEfiVariables = true;
      };

      kernelParams = [
        "amdgpu.abmlevel=0"
        "amdgpu.sg_display=0"
        "amdgpu.exp_hw_support=1"
        "usbcore.autosuspend=-1"
        "usbcore.use_both_schemes=y"
        "xhci_hcd.quirks=0x40"
        "usb-storage.quirks=:u"
        "amd_pstate=active"
        "pcie_aspm=off"
      ];
      initrd.kernelModules = [ "amdgpu" "thunderbolt" ];

      kernelModules = [
        "amdgpu"
        "v4l2loopback"
        "thunderbolt"
        "xhci_pci"
        "kvm-amd"
      ];
      extraModulePackages = [ config.boot.kernelPackages.v4l2loopback ];

      extraModprobeConfig = ''
        options v4l2loopback devices=1 video_nr=10 card_label="Virtual Cam" exclusive_caps=1
        options usbcore autosuspend=-1
        options xhci_hcd quirks=0x40
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
        allowedTCPPorts = [ 22 443 ];
        allowedUDPPorts = [ 5353 ];
        trustedInterfaces = [ "docker0" "br-+" ];
        logReversePathDrops = false;
        logRefusedConnections = false;
      };
      useDHCP = lib.mkDefault false;
      wireless.enable = lib.mkForce true;
    };

    services.resolved = {
      enable = true;
      dnssec = "allow-downgrade";
      domains = [ "~." ];
      fallbackDns = [ "1.1.1.1" "8.8.8.8" "2606:4700:4700::1111" "2001:4860:4860::8888" ];
      dnsovertls = "opportunistic";
    };

    systemd.services.systemd-networkd-wait-online.enable = lib.mkForce false;
    systemd.services.NetworkManager-wait-online = {
      serviceConfig = {
        ExecStart = [ "" "${pkgs.networkmanager}/bin/nm-online -q" ];
        TimeoutStartSec = "30s";
      };
    };

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
            Enable = "Source,Sink,Media,Socket";
            Experimental = true;
            FastConnectable = true;
            JustWorksRepairing = "always";
            MultiProfile = "multiple";
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
        extraPackages = with pkgs; [
          libva-vdpau-driver
          libvdpau-va-gl
          rocmPackages.clr
          rocmPackages.clr.icd
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
      thermald.enable = true;

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
        ACTION=="add", SUBSYSTEM=="usb", ATTR{power/autosuspend}="-1"
        ACTION=="add", SUBSYSTEM=="usb", ATTR{power/control}="on"
        ACTION=="add", SUBSYSTEM=="usb", ATTR{power/autosuspend_delay_ms}="-1"
        ACTION=="add", SUBSYSTEM=="usb", ATTR{bInterfaceClass}=="03", ATTR{power/control}="on"
        ACTION=="add", SUBSYSTEM=="usb", ATTR{bInterfaceClass}=="03", ATTR{power/autosuspend}="-1"
        ACTION=="add", SUBSYSTEM=="usb", ATTR{bDeviceClass}=="09", ATTR{power/control}="on"
        ACTION=="add", SUBSYSTEM=="thunderbolt", ATTR{authorized}=="0", ATTR{authorized}="1"
        ACTION=="add", SUBSYSTEM=="hid", ATTR{power/control}="on"
        ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="32ac", ATTR{power/control}="on"
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

    environment.etc."fwupd/fwupd.conf".text = lib.mkForce ''
      [fwupd]
      UpdateOnBoot=true
    '';

    # ──────────────────────────────────────────────────────────────────────────
    # Virtualization (unchanged)
    # ──────────────────────────────────────────────────────────────────────────
    virtualisation.docker = {
      enable = true;
      enableOnBoot = true;
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
      extraGroups = [ "networkmanager" "wheel" "docker" "wireshark" "disk" "video" "input" "audio" ];
      shell = pkgs.bash;
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
      vim docker git git-lfs gh htop nvme-cli lm_sensors s-tui stress
      dmidecode util-linux gparted usbutils

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

      ollama opencode open-webui alpaca aichat aider-chat

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
      kicad graphviz mako openscad freecad carla strawberry

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
      
      # Wayland-specific variables (will be overridden by session scripts)
      QT_QPA_PLATFORM = "wayland";
      NIXOS_OZONE_WL = "1";
      GDK_BACKEND = "wayland";
      SDL_VIDEODRIVER = "wayland";
      CLUTTER_BACKEND = "wayland";
      MOZ_ENABLE_WAYLAND = "1";
    };

    system.stateVersion = "25.11";
  };
}	

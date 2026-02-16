{ config, pkgs, lib, inputs, nixpkgs-unstable, ... }:

{
  # ============================================================================
  # NixOS Production Configuration — Framework 16 AMD
  # ============================================================================

  imports = [
    ./modules/audio.nix
    ./modules/dcf-community-node.nix
    ./modules/dcf-identity.nix
    ./modules/dcf-tray.nix
    ./modules/security/strict-egress.nix
  ];

  options = {
    custom.steam.enable = lib.mkEnableOption "Steam and gaming support";
  };

  config = {
  # ============================================================================
  # SOPS Secrets Management
  # ============================================================================
  sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    defaultSopsFormat = "yaml";
    age.keyFile = "/etc/sops/age/keys.txt";
  };

  # ──────────────────────────────────────────────────────────────────────────
  # DeMoD Boot Intro
  # ──────────────────────────────────────────────────────────────────────────
  services.boot-intro = {
    enable = true;

    # Source type: generate | database | file
    # "generate" - FFmpeg generation from audio (default, backward compatible)
    # "database" - StreamDB video storage
    # "file" - Pre-rendered video file
    source = "generate";

    # Theme selection — pick your DeMoD palette
    # Options: classic, amber, cyan, magenta, red, white, oligarchy, archibald
    theme = "oligarchy";

    # Branding
    titleText = "Oligarchy";
    bottomText = "Design ≠ Marketing";

    # Optional: Your logo (PNG or animated GIF)
    logoImage = ./assets/demod-logo.png;
    logoScale = 0.4;

    # Audio source — MIDI gets synthesized, audio files normalized
    # soundFile = ./assets/boot-chime.mid;
    # Or use a wav/mp3/flac:
    soundFile = ./assets/boot-intro.wav;
    volume = 40;

    # Optional: Background video (loops behind waveform)
    # backgroundVideo = ./assets/grid-animation.mp4;

    # Visual tuning
    resolution = "2560x1600";  # Match your Framework 16 display
    waveformOpacity = 0.7;
    fadeDuration = 2.0;

    # NEW: GPU acceleration and quality options
    # Enable NVIDIA GPU encoding (requires nvidia drivers)
    # enableGpu = true;
    
    # Enable AMD GPU encoding (requires AMD VAAPI)
    # enableAmdGpu = true;
    
    # Quality preset: fast | balanced | high | ultra
    renderQuality = "balanced";

    # Audio detection tuning
    audioDetection = {
      maxRetries = 5;
      retryDelay = 0.2;
      timeout = 2;
    };

    # NEW: Optional TUI and API (for future video management)
    # enableTui = true;
    # enableApi = true;
    # apiPort = 8080;
  };

  # ──────────────────────────────────────────────────────────────────────────
  # Oligarchy Greeting - The War Room TUI
  # ──────────────────────────────────────────────────────────────────────────
  services.oligarchyGreeting = {
    enable = true;
    
    # Show both banner (16:9 visual) and logo (square icon)
    layout = "adaptive";
    
    # Image settings
    images.banner.enabled = true;
    images.banner.maxHeight = 20;
    
    images.logo.enabled = true;
    images.logo.maxSize = 15;
    
    # Show system info
    showSystemInfo = true;
    
    # Welcome message
    welcomeMessage = "Welcome to Oligarchy — The War Machine";
    
    # Custom links
    customLinks = [
      { name = "Documentation"; url = "https://github.com/ALH477/Oligarchy"; }
      { name = "NixOS Manual"; url = "https://nixos.org/manual/nixos/stable/"; }
      { name = "Package Search"; url = "https://search.nixos.org/packages"; }
    ];
    
    # Tips
    tips = [
      "Press Super+L to lock screen (hyprlock)"
      "Use 'sudo nixos-rebuild switch --flake .' to update system"
      "Run 'nix-collect-garbage -d' to clean old generations"
      "Use 'theme-switcher.sh' to change color palette"
    ];
    
    # TUI settings
    tui = {
      enable = true;
      showLauncher = true;
      launchCommand = "hyprctl dispatch exec kitty";
    };
  };


    # ──────────────────────────────────────────────────────────────────────────
    # DCF Stack Configuration
    # ──────────────────────────────────────────────────────────────────────────

    # Community Node - Set your actual node ID
    custom.dcfCommunityNode = {
      enable = true;
      nodeId = "alh477";  # Your actual node ID
      openFirewall = true;
    };
    # Identity Service - Enable for production (requires secrets to be set up via sops-nix)
    custom.dcfIdentity = {
      enable = false;
      domain = "dcf.demod.ltd";
      port = 4000;
      dataDir = "/var/lib/demod-identity";
    };
    # System Tray Controller (disable if DCF is disabled)
    services.dcf-tray.enable = lib.mkIf config.custom.dcfIdentity.enable true;

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
    # Blipply AI Voice Assistant (integrated with OpenClaw)
    # ──────────────────────────────────────────────────────────────────────────
    config.oligarchy.blipply = {
      enable = true;
      
      # Use OpenClaw gateway for AI (with plugin context)
      ai = {
        model = "llama3.2:3b";  # Can use any model loaded in ai-stack
      };
      
      # Inherit Oligarchy DeMoD theming
      theme = {
        inheritPalette = true;
        avatar = "./assets/blipply-avatar.gif";
        avatarSize = 96;
      };
      
      # Voice settings
      voice = {
        model = "en_US-lessac-medium";
        ttsSpeed = 1.0;
        ttsEnabled = true;
        vadEnabled = true;
      };
      
      # Hotkeys integrated with Oligarchy system
      hotkeys = {
        toggle = "Super+Shift+A";
        pushToTalk = null;  # Set to "Super+Shift+M" for PTT mode
      };
      
      # Default profile
      profiles = {
        active = "default";
        default = {
          name = "Blipply";
          personality = "helpful";
        };
      };
      
      # Context awareness (off by default for privacy)
      context = {
        awareness = false;
        audioDucking = true;  # Lower other audio when speaking
      };
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
    services.xserver.enable = false;

    services.displayManager = {
      sddm = {
        enable = true;
        wayland.enable = true;
      };
      defaultSession = "plasma";
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

      st  # Suckless terminal - lightweight terminal emulator

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

      (brave.override { commandLineArgs = "--password-store=gnome-libsecret"; })
      vlc pandoc kdePackages.okular floorp-bin thunderbird
      kdePackages.xdg-desktop-portal-kde

      blueberry legcord font-awesome fastfetch gnugrep kitty wofi waybar
      hyprpaper brightnessctl zip unzip obsidian

      gimp kdePackages.kdenlive inkscape blender libreoffice krita synfigstudio

      thunar thunar-volman gvfs udiskie polkit_gnome framework-tool

      wl-clipboard grim slurp v4l-utils cliphist hyprpicker wlogout playerctl jq
      hyprlock hypridle libnotify swappy hyprshot satty kdePackages.spectacle
      gpu-screen-recorder gpu-screen-recorder-gtk

      mininet

      ollama opencode open-webui alpaca aichat aider-chat

      (perl.withPackages (ps: with ps; [
        JSON GetoptLong CursesUI ModulePluggable Appcpanminus
      ]))

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
    # Environment (pure Wayland)
    # ──────────────────────────────────────────────────────────────────────────
    environment.sessionVariables = {
      QT_QPA_PLATFORM = "wayland";
      NIXOS_OZONE_WL = "1";
      OBS_USE_EGL = "1";
      QT_QPA_PLATFORMTHEME = "kde";
      GDK_BACKEND = "wayland";
      SDL_VIDEODRIVER = "wayland";
      CLUTTER_BACKEND = "wayland";
      MOZ_ENABLE_WAYLAND = "1";
    };

    system.stateVersion = "25.11";
  };
}	

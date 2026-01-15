{ config, pkgs, lib, inputs, nixpkgs-unstable, ... }:

{
  # ============================================================================
  # NixOS Production Configuration — Framework 16 AMD
  # ============================================================================

  imports = [
    ./modules/audio.nix
  ];

  options = {
    custom.steam.enable = lib.mkEnableOption "Steam and gaming support";
  };

  config = {
    # ──────────────────────────────────────────────────────────────────────────
    # DCF Stack Configuration
    # ──────────────────────────────────────────────────────────────────────────

    # Community Node - Set your actual node ID
    custom.dcfCommunityNode = {
      enable = true;
      nodeId = "alh477";  # Your actual node ID
      openFirewall = true;
    };
    # Identity Service - Enable for production
    custom.dcfIdentity = {
      enable = true;
      domain = "dcf.demod.ltd";
      port = 4000;
      dataDir = "/var/lib/demod-identity";
      secretsFile = "/etc/nixos/secrets/dcf-id.env";
    };
    # System Tray Controller
    services.dcf-tray.enable = true;

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
    };

    # ──────────────────────────────────────────────────────────────────────────
    # Memory Configuration
    # ──────────────────────────────────────────────────────────────────────────
    swapDevices = [
      { device = "/swapfile";
        size = 71680; }  # 70 GiB
    ];
    boot.kernel.sysctl = {
      "vm.swappiness" = 10;
      "vm.dirty_ratio" = 10;
      "vm.dirty_background_ratio" = 5;
    };

    # ──────────────────────────────────────────────────────────────────────────
    # Package Overlays
    # ──────────────────────────────────────────────────────────────────────────
    nixpkgs.overlays = [
      (final: prev: {
        unstable = import nixpkgs-unstable {
          system = prev.system;
          config.allowUnfree = true;
        };
        # Disable libcamera in PipeWire build (replicates disableLibcameraMonitor)
        pipewire = prev.pipewire.override { libcameraSupport = false; };
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
      # Kernel packages set by kernel.nix module

      kernelParams = [
        # AMD GPU
        "amdgpu.abmlevel=0"
        "amdgpu.sg_display=0"
        "amdgpu.exp_hw_support=1"

        # USB stability for Framework 16
        "usbcore.autosuspend=-1"
        "usbcore.use_both_schemes=y"
        "xhci_hcd.quirks=0x40"

        "usb-storage.quirks=:u"

        # CPU power management
        "amd_pstate=active"

        # PCIe stability
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
    # Wayland only

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

    # XDG Portals — Optimized for both Plasma 6 and Hyprland
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
    # OBS Studio (Robust Module Configuration)
    # ──────────────────────────────────────────────────────────────────────────
    programs.obs-studio = {
      enable = true;
      enableVirtualCamera = true;
      plugins = with pkgs.obs-studio-plugins; [
        obs-pipewire-audio-capture   # Per-application audio capture
        obs-vaapi                    # AMD VAAPI hardware encoding
        obs-vkcapture                # Direct Vulkan game capture (great for gaming)
        input-overlay
        # Keyboard/mouse/gamepad overlays

        # Additional production-focused plugins
        advanced-scene-switcher      # Auto-switch scenes based on window, time, etc.
        obs-multi-rtmp               # Simultaneous streaming to multiple platforms (Twitch, YouTube, etc.)
      ];
    };

    # ──────────────────────────────────────────────────────────────────────────
    # Networking
    # ──────────────────────────────────────────────────────────────────────────
    networking = {
      hostName = "nixos";
      # NetworkManager configuration
      networkmanager = {
        enable = true;
        # WiFi backend - wpa_supplicant is more stable on Framework
        wifi = {
          backend = "wpa_supplicant";
          powersave = false;  # Disable power saving for stability
          scanRandMacAddress = false;
          # Some APs don't like random MACs
        };
        # DNS configuration - let NetworkManager handle it
        dns = "systemd-resolved";
        # Connection stability settings
        connectionConfig = {
          "connection.mdns" = 2;
          # Enable mDNS
          "connection.llmnr" = 2;
          # Enable LLMNR
          "ipv6.ip6-privacy" = 2;
          # Prefer temporary addresses
        };
        # Ethernet settings
        ethernet.macAddress = "preserve";
        # Ensure NetworkManager starts properly
        logLevel = "INFO";
      };
      # Firewall configuration
      firewall = {
        enable = true;
        allowPing = true;

        # Default allowed ports (services add their own)
        allowedTCPPorts = [
          22    # SSH
          443   # HTTPS
        ];
        allowedUDPPorts = [
          5353  # mDNS
        ];
        # Trust Docker bridge
        trustedInterfaces = [ "docker0" "br-+" ];
        # Logging (disable for performance, enable for debugging)
        logReversePathDrops = false;
        logRefusedConnections = false;
      };

      # Don't use static nameservers - let NetworkManager/resolved handle it
      # nameservers = [ "1.1.1.1" "8.8.8.8" ];
      # Commented out - conflicts with NM

      # Disable other network management
      useDHCP = lib.mkDefault false;
      # NetworkManager handles this
      wireless.enable = lib.mkForce true;
      # NetworkManager handles WiFi (force to override hardware module)
    };
    # systemd-resolved for DNS resolution
    services.resolved = {
      enable = true;
      dnssec = "allow-downgrade";
      domains = [ "~." ];  # Use resolved for all queries
      fallbackDns = [ "1.1.1.1" "8.8.8.8" "2606:4700:4700::1111" "2001:4860:4860::8888" ];
      dnsovertls = "opportunistic";

      # Extra settings for stability
      extraConfig = ''
        DNSStubListenerExtra=127.0.0.53
        MulticastDNS=yes
        LLMNR=yes
        Cache=yes
        CacheFromLocalhost=no
      '';
    };

    # Disable systemd-networkd-wait-online (conflicts with NetworkManager)
    systemd.services.systemd-networkd-wait-online.enable = lib.mkForce false;
    systemd.services.NetworkManager-wait-online = {
      serviceConfig = {
        ExecStart = [ "" "${pkgs.networkmanager}/bin/nm-online -q" ];
        TimeoutStartSec = "30s";
      };
    };

    # IP Blocker service
    services.demod-ip-blocker = {
      enable = true;
      updateInterval = "24h";
    };

    # ──────────────────────────────────────────────────────────────────────────
    # Hardware
    # ──────────────────────────────────────────────────────────────────────────
    hardware = {
      bluetooth = {
        enable = true;
        powerOnBoot = true;

        # Better Bluetooth settings
        settings = {
          General = {
            Enable = "Source,Sink,Media,Socket";
            Experimental = true;  # Enable battery reporting
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

    # Blueman for Bluetooth GUI management
    services.blueman.enable = true;

    # ──────────────────────────────────────────────────────────────────────────
    # Locale & Time
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
    # System Services
    # ──────────────────────────────────────────────────────────────────────────
    services = {
      # D-Bus message bus
      dbus = {
        enable = true;
        packages = with pkgs; [
          dconf
          gcr  # For secrets/keyring
        ];
      };

      # Input & Hardware
      libinput.enable = true;
      acpid.enable = true;
      udisks2.enable = true;
      gvfs.enable = true;
      fwupd.enable = true;
      fprintd.enable = true;

      # Printing with drivers
      printing = {
        enable = true;
        drivers = with pkgs; [
          gutenprint
          gutenprintBin
          hplip
          brlaser
        ];
      };

      # Avahi for service discovery (mDNS/DNS-SD)
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
      # Power management
      power-profiles-daemon.enable = true;
      tlp.enable = lib.mkForce false;
      # Conflicts with PPD
      thermald.enable = true;
      # UPower for battery management
      upower = {
        enable = true;
        percentageLow = 20;
        percentageCritical = 10;
        percentageAction = 5;
        criticalPowerAction = "Hibernate";
      };
      # Thunderbolt
      hardware.bolt.enable = true;
      # Geoclue2 for location services
      geoclue2 = {
        enable = true;
        enableWifi = true;
      };

      # USB stability via udev
      udev = {
        enable = true;
        extraRules = ''
          # Disable USB autosuspend globally
          ACTION=="add", SUBSYSTEM=="usb", ATTR{power/autosuspend}="-1"
          ACTION=="add", SUBSYSTEM=="usb", ATTR{power/control}="on"
          ACTION=="add", SUBSYSTEM=="usb", ATTR{power/autosuspend_delay_ms}="-1"

          # HID devices - never suspend
          ACTION=="add", SUBSYSTEM=="usb", ATTR{bInterfaceClass}=="03", ATTR{power/control}="on"


          ACTION=="add", SUBSYSTEM=="usb", ATTR{bInterfaceClass}=="03", ATTR{power/autosuspend}="-1"

          # USB hubs - never suspend
          ACTION=="add", SUBSYSTEM=="usb", ATTR{bDeviceClass}=="09", ATTR{power/control}="on"

          # Thunderbolt auto-authorize
          ACTION=="add", SUBSYSTEM=="thunderbolt", ATTR{authorized}=="0", ATTR{authorized}="1"


       # HID runtime PM

          ACTION=="add", SUBSYSTEM=="hid", ATTR{power/control}="on"

          # Framework specific - internal USB devices
          ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="32ac", ATTR{power/control}="on"
        '';
      };

      # Lid and power key handling
      logind = {
        # All settings under settings.Login
        settings.Login = {
          HandleLidSwitch = "ignore";
          HandleLidSwitchExternalPower = "ignore";
          HandleLidSwitchDocked = "ignore";
          HandlePowerKey = "poweroff";
          HandleSuspendKey = "suspend";
          IdleAction = "ignore";
          RuntimeDirectorySize = "50%";
        };
      };
    };

    # ──────────────────────────────────────────────────────────────────────────
    # Security
    # ──────────────────────────────────────────────────────────────────────────
    security = {
      rtkit.enable = true;
      polkit.enable = true;

      # PAM configuration
      pam = {
        services = {
          login = {
            fprintAuth = true;
            enableGnomeKeyring = true;
          };
          sudo = {
            fprintAuth = true;
          };
          sddm = {
            enableGnomeKeyring = true;
          };
          hyprlock = {
            fprintAuth = true;
            enableGnomeKeyring = true;
          };
        };

        # Login limits for audio
        loginLimits = [
          { domain = "@audio";
            type = "-"; item = "rtprio"; value = "99"; }
          { domain = "@audio";
            type = "-"; item = "memlock"; value = "unlimited"; }
          { domain = "@audio";
            type = "-"; item = "nice"; value = "-19"; }
        ];
      };
      # Sudo configuration
      sudo = {
        enable = true;
        wheelNeedsPassword = true;
        extraConfig = ''
          # Preserve environment for nix commands
          Defaults env_keep += "EDITOR VISUAL"
          Defaults env_keep += "NIX_PATH"
          Defaults env_keep += "SSH_AUTH_SOCK"

          # Longer password timeout
          Defaults timestamp_timeout=30


        '';
      };
    };
    # GNOME Keyring for secrets management
    services.gnome.gnome-keyring.enable = true;
    programs.seahorse.enable = true;
    # GUI for keyring

    # Firmware update config
    environment.etc."fwupd/fwupd.conf".text = lib.mkForce ''
      [fwupd]
      UpdateOnBoot=true
    '';

    # ──────────────────────────────────────────────────────────────────────────
    # Virtualization
    # ──────────────────────────────────────────────────────────────────────────
    virtualisation.docker = {
      enable = true;
      # Enable on boot since DCF services depend on it
      enableOnBoot = true;
      # Storage driver - overlay2 is recommended
      storageDriver = "overlay2";
      # Auto cleanup
      autoPrune = {
        enable = true;
        dates = "weekly";
        flags = [ "--all" "--volumes" ];
      };
      # Daemon settings
      daemon.settings = {
        # DNS servers for containers
        dns = [ "1.1.1.1" "8.8.8.8" ];
        # Default address pools for networks
        default-address-pools = [
          { base = "172.17.0.0/16";
            size = 24; }
          { base = "172.18.0.0/16"; size = 24;
          }
        ];

        # Enable live-restore to keep containers running during daemon restart
        live-restore = true;
        # Logging
        log-driver = "json-file";
        log-opts = {
          max-size = "10m";
          max-file = "3";
        };
      };
      # Root dir
      rootless.enable = false;
      # Use normal Docker for DCF
    };
    # Ensure Docker socket is available
    systemd.sockets.docker = {
      wantedBy = [ "sockets.target" ];
    };

    programs.wireshark.enable = true;

    # ──────────────────────────────────────────────────────────────────────────
    # Users
    # ──────────────────────────────────────────────────────────────────────────
    users.users.asher = {
      isNormalUser = true;
      description = "Asher";
      extraGroups = [ "networkmanager" "wheel" "docker" "wireshark" "disk" "video" "audio" ];
      shell = pkgs.bash;
    };

    # ──────────────────────────────────────────────────────────────────────────
    # System Maintenance (Auto GC)
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

        if [ -n "$generations_to_delete" ];
        then
          ${pkgs.nix}/bin/nix-env -p /nix/var/nix/profiles/system --delete-generations $generations_to_delete
        fi

        ${pkgs.nix}/bin/nix-collect-garbage
      '';
      serviceConfig.Type = "oneshot";
    };

    # ──────────────────────────────────────────────────────────────────────────
    # System Packages
    # ──────────────────────────────────────────────────────────────────────────
    environment.systemPackages = with pkgs;
    [
      # System utilities
      vim docker git git-lfs gh htop nvme-cli lm_sensors s-tui stress
      dmidecode util-linux gparted usbutils

      # Python development
      (python3.withPackages (ps: with ps; [
        pip virtualenv cryptography pycryptodome grpcio grpcio-tools
        protobuf numpy matplotlib python-snappy tkinter
      ]))

      # Network tools
      wireshark tcpdump nmap netcat


      inetutils  # ping, traceroute, etc.
      dnsutils   # dig, nslookup
      whois
      iperf3     # Network speed testing
      mtr        # Network diagnostics
      ethtool    # Ethernet diagnostics
      wavemon    # WiFi monitoring
      networkmanagerapplet  # NM tray icon for non-KDE

      #
      # Development toolchains
      cmake gcc gnumake ninja rustc cargo go openssl gnutls pkgconf snappy protobuf

      # Audio production — pure PipeWire focused
      ardour audacity ffmpeg-full libpulseaudio musescore easyeffects
      pkgsi686Linux.libpulseaudio guitarix faust faustlive qpwgraph rnnoise-plugin

      # Virtualization
      qemu
      virt-manager docker-compose docker-buildx

      # Graphics tools
      vulkan-tools vulkan-loader vulkan-validation-layers libva-utils

      # Games (id Software engines)
      dhewm3 darkradiant zandronum

      inputs.minecraft.packages.${pkgs.stdenv.hostPlatform.system}.default

      # Desktop applications
      # Brave configured to use GNOME Libsecret (Correct flag for newer Brave/Chromium)
      (brave.override { commandLineArgs = "--password-store=gnome-libsecret";
      })
      vlc pandoc kdePackages.okular floorp-bin thunderbird

      # Note: OBS Studio configuration moved to 'programs.obs-studio' (see above).
      # OBS dependencies
      kdePackages.xdg-desktop-portal-kde

      # Desktop customization
      blueberry legcord font-awesome fastfetch gnugrep kitty wofi waybar
      hyprpaper
      brightnessctl zip unzip obsidian

      # Creative apps
      gimp kdePackages.kdenlive inkscape blender libreoffice krita synfigstudio

      # File management
      thunar thunar-volman gvfs udiskie polkit_gnome framework-tool

      # Wayland utilities
      wl-clipboard grim
      slurp v4l-utils
      cliphist      # Clipboard history
      hyprpicker    # Color picker
      wlogout       # Logout
      playerctl     # Media player control
      jq            # JSON parsing for scripts
      hyprlock      # Lock screen
      hypridle
          # Idle management
      libnotify     # Desktop notifications (for toggle scripts)

      # Screenshots (Hyprland)
      swappy hyprshot satty


      # Screenshots (KDE)
      kdePackages.spectacle
      gpu-screen-recorder
      gpu-screen-recorder-gtk

      # Networking research
      mininet

      # AI tools
      ollama opencode open-webui alpaca
      aichat

      # Perl development
      (perl.withPackages (ps: with ps;
      [
        JSON GetoptLong CursesUI ModulePluggable Appcpanminus
      ]))

      # Common Lisp development
      (sbcl.withPackages (ps: with ps; [
        cffi cl-ppcre cl-json cl-csv usocket bordeaux-threads log4cl
        trivial-backtrace cl-store hunchensocket fiveam cl-dot cserial-port
      ]))

      # Hardware/embedded development
      libserialport can-utils lksctp-tools cjson ncurses libuuid
      kicad graphviz mako openscad freecad



      # USB boot tools
      unetbootin popsicle gnome-disk-utility
    ] ++ lib.optionals config.custom.steam.enable [
      steam steam-run linuxConsoleTools lutris wineWowPackages.stable
    ];

    # ──────────────────────────────────────────────────────────────────────────
    # Environment
    # ──────────────────────────────────────────────────────────────────────────
    environment.sessionVariables = {
      QT_QPA_PLATFORM = "wayland";
      NIXOS_OZONE_WL = "1";
      OBS_USE_EGL = "1";
      QT_QPA_PLATFORMTHEME = "kde";

      # Additional strict Wayland hints for maximum compatibility & OBS stability
      GDK_BACKEND = "wayland";
      SDL_VIDEODRIVER = "wayland";
      CLUTTER_BACKEND = "wayland";
      MOZ_ENABLE_WAYLAND = "1";
    };

    # ──────────────────────────────────────────────────────────────────────────
    # State Version
    # ──────────────────────────────────────────────────────────────────────────
    system.stateVersion = "25.11";
  };
}

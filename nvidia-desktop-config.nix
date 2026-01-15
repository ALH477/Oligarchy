{ config, pkgs, lib, inputs, nixpkgs-unstable, ... }:

{
  # ============================================================================
  # NixOS Production Configuration — AMD 6-Core / NVIDIA GTX 1660 Desktop
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
    
    # Community Node
    custom.dcfCommunityNode = {
      enable = true;
      nodeId = "alh477";
      openFirewall = true;
    };

    # Identity Service
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
      preset = "pewdiepie";
      acceleration = "cuda";  # Changed to CUDA for NVIDIA GTX 1660
    };

    # ──────────────────────────────────────────────────────────────────────────
    # Audio Configuration (DeMoD Module)
    # ──────────────────────────────────────────────────────────────────────────
    custom.audio = {
      enable = true;
      lowLatency.enable = true;          # Balanced gaming/streaming latency
      bluetooth.highQualityCodecs = true; # LDAC HQ, aptX HD
      disableLibcameraMonitor = true;     # Saves CPU for OBS/v4l2loopback
    };

    # ──────────────────────────────────────────────────────────────────────────
    # Memory Configuration
    # ──────────────────────────────────────────────────────────────────────────
    swapDevices = [
      { device = "/swapfile";
        size = 16384; }  # Adjusted to 16GB for desktop use
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
        # CPU power management for AMD Desktop
        "amd_pstate=active"
        
        # NVIDIA Wayland Requirements
        "nvidia-drm.modeset=1"
        "nvidia-drm.fbdev=1"
      ];
      
      initrd.kernelModules = [ "nvme" "xhci_pci" "ahci" "usbhid" "usb_storage" "sd_mod" ];
      
      kernelModules = [ 
        "kvm-amd"
        "v4l2loopback" 
      ];
      
      extraModulePackages = [ config.boot.kernelPackages.v4l2loopback ];
      
      extraModprobeConfig = ''
        options v4l2loopback devices=1 video_nr=10 card_label="Virtual Cam" exclusive_caps=1
      '';
    };

    # ──────────────────────────────────────────────────────────────────────────
    # Display & Desktop Environment
    # ──────────────────────────────────────────────────────────────────────────
    services.xserver.enable = false; # Wayland only
    
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
    
    # XDG Portals
    xdg.portal = {
      enable = true;
      extraPortals = [
        pkgs.xdg-desktop-portal-gtk
        pkgs.xdg-desktop-portal-hyprland
        pkgs.kdePackages.xdg-desktop-portal-kde
      ];
      config = {
        common.default = [ "gtk" ];
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
        obs-nvfbc              # NVIDIA specific capture
        input-overlay        
        advanced-scene-switcher
        obs-multi-rtmp
      ];
    };

    # ──────────────────────────────────────────────────────────────────────────
    # Networking
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
      extraConfig = ''
        DNSStubListenerExtra=127.0.0.53
        MulticastDNS=yes
        LLMNR=yes
        Cache=yes
        CacheFromLocalhost=no
      '';
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
    # Hardware & Graphics (NVIDIA Optimized)
    # ──────────────────────────────────────────────────────────────────────────
    services.xserver.videoDrivers = [ "nvidia" ];

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
          nvidia-vaapi-driver
          egl-wayland
        ];
      };

      nvidia = {
        modesetting.enable = true;
        powerManagement.enable = false; # Fine for desktops
        powerManagement.finegrained = false;
        open = false; # Use proprietary for GTX 1660
        nvidiaSettings = true;
        package = config.boot.kernelPackages.nvidia_x11;
      };
    };
    
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
      dbus = {
        enable = true;
        packages = with pkgs; [ dconf gcr ];
      };
      
      libinput.enable = true;
      acpid.enable = true;
      udisks2.enable = true;
      gvfs.enable = true;
      fwupd.enable = true;
      fprintd.enable = true; # Can disable if desktop has no reader
      
      printing = {
        enable = true;
        drivers = with pkgs; [ gutenprint gutenprintBin hplip brlaser ];
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

      # Desktop power management (simpler than laptop)
      power-profiles-daemon.enable = true;
      tlp.enable = lib.mkForce false;
      
      upower = {
        enable = true;
        percentageLow = 20;
        percentageCritical = 10;
        percentageAction = 5;
        criticalPowerAction = "Hibernate";
      };

      # Location
      geoclue2 = {
        enable = true;
        enableWifi = true;
      };
      
      udev = {
        enable = true;
        # Removed laptop-specific USB autosuspend rules
        extraRules = ''
          # Thunderbolt auto-authorize (if equipped)
          ACTION=="add", SUBSYSTEM=="thunderbolt", ATTR{authorized}=="0", ATTR{authorized}="1"
        '';
      };
      
      logind = {
        settings.Login = {
          HandlePowerKey = "poweroff";
          HandleSuspendKey = "suspend";
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
      
      pam = {
        services = {
          login = {
            fprintAuth = true;
            enableGnomeKeyring = true;
          };
          sudo.fprintAuth = true;
          sddm.enableGnomeKeyring = true;
          hyprlock = {
            fprintAuth = true;
            enableGnomeKeyring = true;
          };
        };
        
        loginLimits = [
          { domain = "@audio"; type = "-"; item = "rtprio"; value = "99"; }
          { domain = "@audio"; type = "-"; item = "memlock"; value = "unlimited"; }
          { domain = "@audio"; type = "-"; item = "nice"; value = "-19"; }
        ];
      };

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
    # Virtualization
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
      inetutils dnsutils whois iperf3 mtr ethtool wavemon
      networkmanagerapplet

      # Development toolchains
      cmake gcc gnumake ninja rustc cargo go openssl gnutls pkgconf snappy protobuf

      # Audio production
      ardour audacity ffmpeg-full jack2 qjackctl libpulseaudio musescore easyeffects
      pkgsi686Linux.libpulseaudio pavucontrol guitarix faust faustlive qpwgraph rnnoise-plugin

      # Virtualization
      qemu virt-manager docker-compose docker-buildx

      # Graphics tools (NVIDIA Adjusted)
      vulkan-tools vulkan-loader vulkan-validation-layers libva-utils
      nvidia-vaapi-driver

      # Games
      dhewm3 darkradiant zandronum
      inputs.minecraft.packages.${pkgs.stdenv.hostPlatform.system}.default

      # Desktop applications
      (brave.override { commandLineArgs = "--password-store=gnome-libsecret"; })
      vlc pandoc kdePackages.okular floorp-bin thunderbird
      kdePackages.xdg-desktop-portal-kde

      # Desktop customization
      blueberry legcord font-awesome fastfetch gnugrep kitty wofi waybar
      hyprpaper brightnessctl zip unzip obsidian

      # Creative apps
      gimp kdePackages.kdenlive inkscape blender libreoffice krita synfigstudio

      # File management
      thunar thunar-volman gvfs udiskie polkit_gnome framework-tool

      # Wayland utilities
      wl-clipboard grim slurp v4l-utils
      cliphist hyprpicker wlogout playerctl jq hyprlock hypridle
      libnotify

      # Screenshots
      swappy hyprshot satty
      kdePackages.spectacle
      gpu-screen-recorder
      gpu-screen-recorder-gtk

      # Networking research
      mininet

      # AI tools (CUDA enabled via Ollama service)
      ollama opencode open-webui alpaca aichat

      # Perl development
      (perl.withPackages (ps: with ps; [
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
      QT_QPA_PLATFORM = "wayland;xcb";
      NIXOS_OZONE_WL = "1";
      OBS_USE_EGL = "1";
      QT_QPA_PLATFORMTHEME = "kde";
      
      # NVIDIA Specific
      LIBVA_DRIVER_NAME = "nvidia";
      GBM_BACKEND = "nvidia-drm";
      __GLX_VENDOR_LIBRARY_NAME = "nvidia";
    };

    # ──────────────────────────────────────────────────────────────────────────
    # State Version
    # ──────────────────────────────────────────────────────────────────────────
    system.stateVersion = "25.11";
  };
}

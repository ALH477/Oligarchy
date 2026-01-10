{ config, pkgs, lib, inputs, nixpkgs-unstable, ... }:

{
  # ============================================================================
  # NixOS Production Configuration — Framework 16 AMD
  # ============================================================================

  options = {
    custom.steam.enable = lib.mkEnableOption "Steam and gaming support";
  };

  config = {
    # ──────────────────────────────────────────────────────────────────────────
    # DCF Stack Configuration
    # ──────────────────────────────────────────────────────────────────────────
    
    custom.dcfCommunityNode = {
      enable = true;
      nodeId = "alh477";
      openFirewall = true;
    };
    
    custom.dcfIdentity = {
      enable = true;
      domain = "dcf.demod.ltd";
      port = 4000;
      dataDir = "/var/lib/demod-identity";
      secretsFile = "/etc/nixos/secrets/dcf-id.env";
    };
    
    services.dcf-tray.enable = true;

    # ──────────────────────────────────────────────────────────────────────────
    # Local AI Stack (Ollama)
    # ──────────────────────────────────────────────────────────────────────────
    services.ollamaAgentic = {
      enable = true;
      preset = "pewdiepie";
      acceleration = "rocm";
      advanced.rocm.gfxVersionOverride = "11.0.2";
    };

    # ──────────────────────────────────────────────────────────────────────────
    # Memory Configuration
    # ──────────────────────────────────────────────────────────────────────────
    swapDevices = [
      { device = "/swapfile"; size = 71680; }
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
          system = prev.stdenv.hostPlatform.system;
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
        common.default = [ "kde" "gtk" ];
        hyprland.default = [ "hyprland" "gtk" ];
        kde.default = [ "kde" "gtk" ];
      };
    };

    # ──────────────────────────────────────────────────────────────────────────
    # Networking — iwd backend (corrected wireless option path)
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

      # Correct path for iwd enablement (required for NetworkManager iwd backend)
      wireless.enable = true;
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
    # Hardware
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
      fprintd.enable = true;
      
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
      
      udev = {
        enable = true;
        extraRules = ''
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
      };
      
      pipewire = {
        enable = true;
        alsa.enable = true;
        alsa.support32Bit = true;
        pulse.enable = true;
        jack.enable = true;
        
        wireplumber = {
          enable = true;
          extraConfig = {
            "10-disable-camera" = {
              "wireplumber.profiles" = {
                main = { "monitor.libcamera" = "disabled"; };
              };
            };
          };
        };
        
        extraConfig = {
          pipewire."92-low-latency" = {
            "context.properties" = {
              "default.clock.rate" = 48000;
              "default.clock.quantum" = 1024;
              "default.clock.min-quantum" = 512;
              "default.clock.max-quantum" = 2048;
            };
          };
          
          pipewire-pulse."92-low-latency" = {
            "context.modules" = [
              {
                name = "libpipewire-module-protocol-pulse";
                args = {
                  "pulse.min.req" = "1024/48000";
                  "pulse.default.req" = "1024/48000";
                  "pulse.max.req" = "2048/48000";
                  "pulse.min.quantum" = "1024/48000";
                  "pulse.max.quantum" = "2048/48000";
                };
              }
            ];
            "stream.properties" = {
              "node.latency" = "1024/48000";
              "resample.quality" = 4;
            };
          };
        };
      };
      
      logind = {
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
      
      pam = {
        services = {
          login = { fprintAuth = true; enableGnomeKeyring = true; };
          sudo = { fprintAuth = true; };
          sddm = { enableGnomeKeyring = true; };
          hyprlock = { fprintAuth = true; enableGnomeKeyring = true; };
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
        
        if [ -n "$generations_to_delete" ]; then
          ${pkgs.nix}/bin/nix-env -p /nix/var/nix/profiles/system --delete-generations $generations_to_delete
        fi
        
        ${pkgs.nix}/bin/nix-collect-garbage
      '';
      serviceConfig.Type = "oneshot";
    };

    # ──────────────────────────────────────────────────────────────────────────
    # System Packages
    # ──────────────────────────────────────────────────────────────────────────
    environment.systemPackages = with pkgs; [
      vim docker git git-lfs gh htop nvme-cli lm_sensors s-tui stress
      dmidecode util-linux gparted usbutils

      (python3.withPackages (ps: with ps; [
        pip virtualenv cryptography pycryptodome grpcio grpcio-tools
        protobuf numpy matplotlib python-snappy tkinter
      ]))

      wireshark tcpdump nmap netcat
      inetutils dnsutils whois iperf3 mtr ethtool wavemon networkmanagerapplet

      cmake gcc gnumake ninja rustc cargo go openssl gnutls pkgconf snappy protobuf

      ardour audacity ffmpeg-full jack2 qjackctl libpulseaudio
      pkgsi686Linux.libpulseaudio pavucontrol guitarix faust faustlive

      qemu virt-manager docker-compose docker-buildx

      vulkan-tools vulkan-loader vulkan-validation-layers libva-utils

      dhewm3 darkradiant zandronum
      inputs.minecraft.packages.${pkgs.stdenv.hostPlatform.system}.default

      ((brave.overrideAttrs (old: {
        postFixup = (old.postFixup or "") + ''
          sed -i '/Exec=/ s|$| --password-store=basic|' $out/share/applications/*.desktop
        '';
      })))
      vlc pandoc kdePackages.okular obs-studio unstable.floorp-bin thunderbird

      obs-studio-plugins.wlrobs
      obs-studio-plugins.obs-pipewire-audio-capture
      obs-studio-plugins.obs-vaapi
      obs-studio-plugins.obs-vkcapture
      obs-studio-plugins.input-overlay
      kdePackages.xdg-desktop-portal-kde

      blueberry legcord font-awesome fastfetch gnugrep kitty wofi waybar
      hyprpaper brightnessctl zip unzip obsidian

      gimp kdePackages.kdenlive inkscape blender libreoffice krita synfigstudio

      thunar thunar-volman gvfs udiskie polkit_gnome framework-tool

      wl-clipboard grim slurp v4l-utils
      cliphist hyprpicker wlogout playerctl jq hyprlock hypridle libnotify

      swappy hyprshot satty

      kdePackages.spectacle
      gpu-screen-recorder
      gpu-screen-recorder-gtk

      mininet

      ollama opencode open-webui alpaca aichat

      (perl.withPackages (ps: with ps; [
        JSON GetoptLong CursesUI ModulePluggable Appcpanminus
      ]))

      (sbcl.withPackages (ps: with ps; [
        cffi cl-ppcre cl-json cl-csv usocket bordeaux-threads log4cl
        trivial-backtrace cl-store hunchensocket fiveam cl-dot cserial-port
      ]))

      libserialport can-utils lksctp-tools cjson ncurses libuuid
      kicad graphviz mako openscad freecad

      unetbootin popsicle gnome-disk-utility
    ] ++ lib.optionals config.custom.steam.enable [
      steam steam-run linuxConsoleTools lutris wineWowPackages.stable
    ];

    # ──────────────────────────────────────────────────────────────────────────
    # Environment
    # ──────────────────────────────────────────────────────────────────────────
    environment.etc."jack/conf.xml".text = ''
      <?xml version="1.0"?>
      <jack>
        <engine>
          <param name="driver" value="alsa"/>
          <param name="realtime" value="true"/>
        </engine>
      </jack>
    '';

    environment.sessionVariables = {
      QT_QPA_PLATFORM = "wayland;xcb";
      NIXOS_OZONE_WL = "1";
      OBS_USE_EGL = "1";
      QT_QPA_PLATFORMTHEME = "kde";
      XDG_CURRENT_DESKTOP = "KDE";
    };

    # ──────────────────────────────────────────────────────────────────────────
    # State Version
    # ──────────────────────────────────────────────────────────────────────────
    system.stateVersion = "25.11";
  };
}

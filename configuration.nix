{ config, pkgs, lib, inputs, nixpkgs-unstable, ... }:

{
  imports = [
    ./modules/hardware-configuration.nix
    ./modules/agentic-local-ai.nix
    ./modules/dcf-community-node.nix
    ./modules/dcf-identity.nix
    ./modules/dcf-tray.nix
    ./modules/cachyos-bore-kernel.nix  # Fixed: uses Zen kernel (or CachyOS 6.12 if hashes updated)
  ];

  options = {
    custom.steam.enable = lib.mkEnableOption "Steam and gaming support";
  };

  config = {
    # ENABLE THE NEW MODULE
    services.dcf-tray.enable = false;

    swapDevices = [
      { device = "/swapfile"; size = 71680; }  # 70 * 1024 MiB
    ];

    # Reduce swappiness to prevent latency
    boot.kernel.sysctl."vm.swappiness" = 10;

    # Package management
    nixpkgs = {
      overlays = [
        (final: prev: {
          unstable = import nixpkgs-unstable {
            system = prev.system;
            config.allowUnfree = true;
          };
        })
      ];
    };

    custom.dcfCommunityNode.nodeId = "RENAME";

    custom.dcfIdentity = {
      enable = false;
      secretsFile = "/etc/nixos/modules/secrets/dcf-id.env";
    };

    # Local AI service
    services.ollamaAgentic = {
      enable = true;
      preset = "pewdiepie";
      acceleration = "rocm";
      advanced.rocm.gfxVersionOverride = "11.0.2";
    };

    # Gaming
    custom.steam.enable = true;

    # Boot configuration
    boot = {
      binfmt.emulatedSystems = [ "aarch64-linux" ];
      loader = {
        systemd-boot.enable = true;
        efi.canTouchEfiVariables = true;
      };
      
      # kernelPackages set by cachyos-bore-kernel module via mkForce

      kernelParams = [ 
        "amdgpu.abmlevel=0"
        "amdgpu.sg_display=0"
        "amdgpu.exp_hw_support=1"
        # USB stability fixes for Framework 16
        "usbcore.autosuspend=-1"           # Disable USB autosuspend globally
        "usbcore.use_both_schemes=y"       # Try both USB enumeration schemes
        "xhci_hcd.quirks=0x40"             # USB controller quirks
        "usb-storage.quirks=:u"            # USB storage quirks
        "amd_pstate=active"                # Prefer active pstate for stability
        # Additional USB/PCI stability
        "pcie_aspm=off"                    # Disable PCIe power management (can cause USB issues)
      ];

      initrd.kernelModules = [ "amdgpu" "thunderbolt" ];
      kernelModules = [ "amdgpu" "v4l2loopback" "thunderbolt" "xhci_pci" ];
      extraModulePackages = [ config.boot.kernelPackages.v4l2loopback ];
      
      extraModprobeConfig = ''
        options v4l2loopback devices=1 video_nr=10 card_label="Virtual Cam" exclusive_caps=1
        # Disable USB autosuspend at module level
        options usbcore autosuspend=-1
        options xhci_hcd quirks=0x40
      '';
    };

    # Wayland
    services.xserver.enable = false;

    services.displayManager = {
      sddm = {
        enable = true;
        wayland.enable = true;
        # enableHidpi removed - deprecated in NixOS 24.05+
      };
      defaultSession = "plasma"; 
    };

    services.desktopManager.plasma6.enable = true;

    programs.hyprland = {
      enable = true;
      xwayland.enable = true;
      package = pkgs.hyprland;
    };
    
    # Ensure Hyprland finds the system config
    # Option 1: Symlink /etc/hypr to user config location
    system.activationScripts.hyprlandConfig = lib.stringAfter [ "users" ] ''
      # Create hyprland config symlink for user
      USER_HOME="/home/asher"
      if [ -d "$USER_HOME" ]; then
        mkdir -p "$USER_HOME/.config/hypr"
        chown asher:users "$USER_HOME/.config/hypr"
        
        # Symlink system config if user doesn't have their own
        if [ ! -f "$USER_HOME/.config/hypr/hyprland.conf" ] || [ -L "$USER_HOME/.config/hypr/hyprland.conf" ]; then
          ln -sf /etc/hypr/hyprland.conf "$USER_HOME/.config/hypr/hyprland.conf"
          chown -h asher:users "$USER_HOME/.config/hypr/hyprland.conf"
        fi
        
        # Symlink helper scripts
        for script in lid.sh toggle_clamshell.sh; do
          if [ -f "/etc/hypr/$script" ]; then
            ln -sf "/etc/hypr/$script" "$USER_HOME/.config/hypr/$script"
            chown -h asher:users "$USER_HOME/.config/hypr/$script"
          fi
        done
      fi
    '';
    
    services.demod-ip-blocker = {
      enable = true;
      updateInterval = "24h";
    };

    systemd.defaultUnit = lib.mkForce "graphical.target";

    xdg.portal = {
      enable = true;
      extraPortals = [ 
        pkgs.xdg-desktop-portal-gtk 
        pkgs.xdg-desktop-portal-hyprland
        pkgs.kdePackages.xdg-desktop-portal-kde
      ];
      # Portal config per desktop
      config = {
        common.default = [ "gtk" ];
        hyprland.default = [ "hyprland" "gtk" ];
        kde.default = [ "kde" "gtk" ];
      };
    };

    # Networking
    networking = {
      hostName = "nixos";
      networkmanager = {
        enable = true;
        wifi.powersave = false;  # Disable WiFi power saving for stability
      };
      # Ensure DNS works during rebuild
      nameservers = [ "1.1.1.1" "8.8.8.8" ];
    };

    # Hardware
    hardware = {
      bluetooth = {
        enable = true;
        powerOnBoot = true;
      };
      
      enableRedistributableFirmware = true;
      
      graphics = {
        enable = true;
        enable32Bit = true;
        # Removed invalid 'package = pkgs.mesa' - Mesa is managed automatically
        
        extraPackages = with pkgs; [
          # Package renames for 25.11:
          # - amdvlk removed (RADV is default)
          # - vaapiVdpau → libva-vdpau-driver
          libva-vdpau-driver
          libvdpau-va-gl
          rocmPackages.clr
          rocmPackages.clr.icd
        ];
        # Removed extraPackages32 amdvlk - RADV handles 32-bit too
      };
    };

    # Removed cpuFreqGovernor - conflicts with power-profiles-daemon
    # power-profiles-daemon handles governor switching dynamically

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

    # Services
    services = {
      libinput.enable = true;
      acpid.enable = true;
      printing.enable = true;
      udisks2.enable = true;
      gvfs.enable = true;
      power-profiles-daemon.enable = true;
      fwupd.enable = true;
      fprintd.enable = true;
      
      # USB stability - disable TLP if enabled elsewhere (conflicts with PPD)
      tlp.enable = lib.mkForce false;
      
      # Aggressive USB autosuspend disable via udev for Framework
      udev.extraRules = ''
        # Disable USB autosuspend for ALL devices immediately
        ACTION=="add", SUBSYSTEM=="usb", ATTR{power/autosuspend}="-1"
        ACTION=="add", SUBSYSTEM=="usb", ATTR{power/control}="on"
        ACTION=="add", SUBSYSTEM=="usb", ATTR{power/autosuspend_delay_ms}="-1"
        
        # HID devices (mice, keyboards) - never suspend
        ACTION=="add", SUBSYSTEM=="usb", ATTR{bInterfaceClass}=="03", ATTR{power/control}="on"
        ACTION=="add", SUBSYSTEM=="usb", ATTR{bInterfaceClass}=="03", ATTR{power/autosuspend}="-1"
        
        # USB hubs - never suspend (Framework uses internal hubs)
        ACTION=="add", SUBSYSTEM=="usb", ATTR{bDeviceClass}=="09", ATTR{power/control}="on"
        
        # Framework-specific USB-C/Thunderbolt stability
        ACTION=="add", SUBSYSTEM=="thunderbolt", ATTR{authorized}=="0", ATTR{authorized}="1"
        
        # Disable runtime PM for USB HID devices
        ACTION=="add", SUBSYSTEM=="hid", ATTR{power/control}="on"
      '';

      pipewire = {
        enable = true;
        alsa.enable = true;
        alsa.support32Bit = true;
        pulse.enable = true;
        jack.enable = true;
        
        extraConfig.pipewire."90-custom" = {
          "default.clock.quantum" = 1024;
          "default.clock.min-quantum" = 512;
          "default.clock.max-quantum" = 2048;
        };
      };
      
      # Lid switch handling - use new settings format
      logind.settings.Login = {
        HandleLidSwitch = "ignore";
        HandleLidSwitchExternalPower = "ignore";
        HandleLidSwitchDocked = "ignore";
      };
    };
    
    # Thunderbolt device management (outside services block)
    services.hardware.bolt.enable = true;

    # Security
    security = {
      rtkit.enable = true;
      polkit.enable = true;
      pam.services = {
        login.fprintAuth = true;
        sudo.fprintAuth = true;
      };
    };

    environment.etc."fwupd/fwupd.conf".text = lib.mkForce ''
      [fwupd]
      UpdateOnBoot=true
    '';

    # Virtualization
    virtualisation.docker.enable = true;

    programs.wireshark.enable = true;

    # User configuration
    users.users.asher = {
      isNormalUser = true;
      description = "Asher";
      extraGroups = [ "networkmanager" "wheel" "docker" "wireshark" "disk" ];
      shell = pkgs.bash;
    };

    # System maintenance
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

    # System packages organized by category
    environment.systemPackages = with pkgs; [
      vim docker git git-lfs gh htop nvme-cli lm_sensors s-tui stress 
      dmidecode util-linux gparted usbutils

      (python3.withPackages (ps: with ps; [
        pip virtualenv cryptography pycryptodome grpcio grpcio-tools
        protobuf numpy matplotlib python-snappy tkinter
        # skidl removed - incompatible with Python 3.13 (depends on 'future')
      ]))

      wireshark tcpdump nmap netcat

      cmake gcc gnumake ninja rustc cargo go openssl gnutls pkgconf snappy protobuf

      ardour audacity ffmpeg-full jack2 qjackctl libpulseaudio 
      pkgsi686Linux.libpulseaudio pavucontrol guitarix faust faustlive

      qemu virt-manager docker-compose docker-buildx

      vulkan-tools vulkan-loader vulkan-validation-layers libva-utils

      dhewm3 darkradiant zandronum

      inputs.minecraft.packages.${pkgs.stdenv.hostPlatform.system}.default

      brave vlc pandoc kdePackages.okular obs-studio firefox thunderbird
      
      # OBS Wayland/Plasma 6 compatibility
      obs-studio-plugins.wlrobs              # Wayland screen capture
      obs-studio-plugins.obs-pipewire-audio-capture  # PipeWire audio
      obs-studio-plugins.obs-vaapi           # Hardware encoding
      obs-studio-plugins.obs-vkcapture       # Vulkan/OpenGL game capture
      obs-studio-plugins.input-overlay       # Input overlay for streaming
      kdePackages.xdg-desktop-portal-kde     # KDE screen sharing portal
      
      blueberry legcord font-awesome fastfetch gnugrep kitty wofi waybar 
      hyprpaper brightnessctl zip unzip obsidian

      gimp kdePackages.kdenlive inkscape blender libreoffice krita synfigstudio

      thunar thunar-volman gvfs udiskie polkit_gnome framework-tool

      wl-clipboard grim slurp v4l-utils
      
      # Hyprland screenshot stack
      swappy           # Screenshot annotation/editing
      hyprshot         # Hyprland screenshot wrapper
      satty            # Modern screenshot annotation tool
      
      # KDE/Plasma screenshot + recording
      kdePackages.spectacle       # KDE screenshot tool
      gpu-screen-recorder         # Low-overhead GPU recording
      gpu-screen-recorder-gtk     # GTK frontend for gpu-screen-recorder

      mininet

      ollama opencode open-webui alpaca aichat
      # oterm removed - broken dependency (fastmcp requires mcp<1.17.0)

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

    # Steam configuration
    programs.steam = lib.mkIf config.custom.steam.enable {
      enable = true;
      extraCompatPackages = [ pkgs.proton-ge-bin ];
    };

    hardware.steam-hardware = lib.mkIf config.custom.steam.enable {
      enable = true;
    };

    programs.gamemode = lib.mkIf config.custom.steam.enable {
      enable = true;
    };

    # Configuration files
    environment.etc = {
      "jack/conf.xml".text = ''
        <?xml version="1.0"?>
        <jack>
          <engine>
            <param name="driver" value="alsa"/>
            <param name="realtime" value="true"/>
          </engine>
        </jack>
      '';

      "hypr/hyprland.conf".text = ''
        monitor=,preferred,auto,1
        exec-once=waybar
        exec-once=hyprpaper
        exec-once=mako &
        exec-once=udiskie &
        exec-once=${pkgs.polkit_gnome}/libexec/polkit-gnome-authentication-agent-1
        # exec-once=dcf-tray  # Handled automatically by module XDG autostart now
        
        bind=SUPER,Return,exec,kitty
        bind=SUPER,Q,killactive
        bind=SUPER,M,exit
        bind=SUPER,E,exec,thunar
        bind=SUPER,Space,exec,wofi --show drun
        
        # Screenshot bindings
        bind=,Print,exec,hyprshot -m output                    # Full screen
        bind=SUPER,Print,exec,hyprshot -m window               # Active window
        bind=SUPER SHIFT,Print,exec,hyprshot -m region         # Select region
        bind=SUPER ALT,Print,exec,hyprshot -m region --clipboard-only  # Region to clipboard
        bind=SUPER CTRL,S,exec,grim -g "$(slurp)" - | swappy -f -      # Region with editor
      '';

      "hypr/lid.sh" = {
        text = ''
          #!/usr/bin/env bash
          hyprctl keyword monitor "eDP-2,disable"
          if [[ $1 == "open" ]]; then
            hyprctl keyword monitor "eDP-2,2560x1600@165,auto,1"
          fi
        '';
        mode = "0755";
      };

      "hypr/toggle_clamshell.sh" = {
        text = ''
          #!/usr/bin/env bash
          INTERNAL="eDP-2"
          
          if [[ "$(hyprctl monitors)" =~ DP- ]]; then
            if hyprctl monitors | grep -q "$INTERNAL" && \
               ! hyprctl monitors | grep -q "$INTERNAL.*(disabled)"; then
              hyprctl keyword monitor "$INTERNAL,disable"
              notify-send "Clamshell Mode" "Laptop screen disabled"
            else
              hyprctl keyword monitor "$INTERNAL,2560x1600@165,auto,1"
              notify-send "Clamshell Mode" "Laptop screen enabled"
            fi
          else
            notify-send "Clamshell Mode" "No external monitor connected"
          fi
        '';
        mode = "0755";
      };
    };

    environment.sessionVariables = {
      QT_QPA_PLATFORM = "wayland;xcb";
      NIXOS_OZONE_WL = "1";
      # OBS Wayland support
      OBS_USE_EGL = "1";
      QT_QPA_PLATFORMTHEME = "kde";
    };

    # User confirmed running 25.11 (unstable)
    system.stateVersion = "25.11";
  };
}

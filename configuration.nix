# Copyright (c) 2026, DeMoD LLC
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#
# 1. Redistributions of source code must retain the above copyright notice, this
#    list of conditions and the following disclaimer.
#
# 2. Redistributions in binary form must reproduce the above copyright notice,
#    this list of conditions and the following disclaimer in the documentation
#    and/or other materials provided with the distribution.
#
# 3. Neither the name of the copyright holder nor the names of its
#    contributors may be used to endorse or promote products derived from
#    this software without specific prior written permission.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
# AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
# CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
# OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
# OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

{ config, pkgs, lib, inputs, nixpkgs-unstable, ... }:

{
  imports = [
    ./modules/hardware-configuration.nix
    ./modules/agentic-local-ai.nix
    ./modules/dcf-community-node.nix
    ./modules/dcf-identity.nix
    inputs.demod-ip-blocker.nixosModules.default
  ];

  options = {
    custom.steam.enable = lib.mkEnableOption "Steam and gaming support";
  };

  config = {
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
      config.allowUnfree = true;
    };

    custom.dcfCommunityNode.nodeId = "zSK0KNzNgerIjBHuSv01bqEgnz1XG6uj";

    custom.dcfIdentity = {
      enable = true;
      secretsFile = "/etc/nixos/secrets/dcf-id.env";
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
      
      kernelPackages = pkgs.linuxPackages_latest;
      kernelParams = [ 
        "amdgpu.abmlevel=0"
        "amdgpu.sg_display=0"
        "amdgpu.exp_hw_support=1"
      ];
      initrd.kernelModules = [ "amdgpu" ];
      kernelModules = [ "amdgpu" "v4l2loopback" ];
      extraModulePackages = [ config.boot.kernelPackages.v4l2loopback ];
      extraModprobeConfig = ''
        options v4l2loopback devices=1 video_nr=10 card_label="Virtual Cam" exclusive_caps=1
      '';
    };

    # Display and window management
    services.displayManager = {
      sddm = {
        enable = true;
        wayland.enable = false;
      };
      defaultSession = "hyprland";
    };

    services.xserver = {
      enable = true;
      videoDrivers = [ "amdgpu" ];
      desktopManager.cinnamon.enable = true;
      windowManager.dwm.enable = true;
    };

    services.demod-ip-blocker = {
      enable = true;
      updateInterval = "24h"; # Background refresh for long uptimes
    };

    programs.hyprland = {
      enable = true;
      xwayland.enable = true;
      package = pkgs.hyprland;
    };

    systemd.defaultUnit = lib.mkForce "graphical.target";

    xdg.portal = {
      enable = true;
      extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
      config.common.default = "*";
    };

    # Networking
    networking = {
      hostName = "nixos";
      networkmanager.enable = true;
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
        package = pkgs.mesa;
        
        extraPackages = with pkgs; [
          amdvlk
          vaapiVdpau
          libvdpau-va-gl
          rocmPackages.clr
          rocmPackages.clr.icd
        ];
        extraPackages32 = with pkgs.pkgsi686Linux; [ amdvlk ];
      };
    };

    powerManagement.cpuFreqGovernor = "performance";

    # Localization
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
      
      logind.extraConfig = ''
        HandleLidSwitch=ignore
        HandleLidSwitchExternalPower=ignore
        HandleLidSwitchDocked=ignore
      '';
    };

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
      # Core system tools
      vim docker git git-lfs gh htop nvme-cli lm_sensors s-tui stress 
      dmidecode util-linux gparted usbutils

      # Python environment
      (python3Full.withPackages (ps: with ps; [
        pip virtualenv cryptography pycryptodome grpcio grpcio-tools
        protobuf numpy matplotlib python-snappy skidl
      ]))

      # Networking and security
      wireshark tcpdump nmap netcat

      # Development tools
      cmake gcc gnumake ninja rustc cargo go openssl gnutls pkgconf snappy protobuf

      # Multimedia and audio
      ardour audacity ffmpeg-full jack2 qjackctl libpulseaudio 
      pkgsi686Linux.libpulseaudio pavucontrol guitarix faust faustlive

      # Virtualization
      qemu virt-manager docker-compose docker-buildx

      # Graphics tools
      vulkan-tools vulkan-loader vulkan-validation-layers libva-utils

      # Gaming (Doom 3, etc)
      dhewm3 darkradiant zandronum

      # Desktop applications
      brave vlc pandoc kdePackages.okular obs-studio firefox thunderbird
      
      # Desktop utilities
      blueberry legcord font-awesome fastfetch gnugrep kitty wofi waybar 
      hyprpaper brightnessctl zip unzip obsidian

      # Creative tools
      gimp kdePackages.kdenlive inkscape blender libreoffice krita synfigstudio

      # File management
      xfce.thunar xfce.thunar-volman gvfs udiskie polkit_gnome framework-tool

      # Screen utilities
      wl-clipboard grim slurp v4l-utils

      # Network simulation
      mininet

      # AI tools
      ollama opencode open-webui alpaca aichat oterm

      # Language environments
      (perl.withPackages (ps: with ps; [ 
        JSON GetoptLong CursesUI ModulePluggable Appcpanminus 
      ]))
      
      (sbcl.withPackages (ps: with ps; [
        cffi cl-ppcre cl-json cl-csv usocket bordeaux-threads log4cl 
        trivial-backtrace cl-store hunchensocket fiveam cl-dot cserial-port
      ]))

      # Hardware tools
      libserialport can-utils lksctp-tools cjson ncurses libuuid 
      kicad graphviz mako openscad freecad

      # Xorg fallback
      xorg.xinit

      # USB tools
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
        bind=SUPER,Return,exec,kitty
        bind=SUPER,Q,killactive
        bind=SUPER,M,exit
        bind=SUPER,E,exec,thunar
        bind=SUPER,Space,exec,wofi --show drun
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
    };

    system.stateVersion = "25.11";
  };
}

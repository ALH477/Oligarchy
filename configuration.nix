{ config, pkgs, lib, nixpkgs-unstable, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./agentic-local-ai.nix  # Assuming this defines the custom services.ollamaAgentic module
    # Recommended for Framework 16 (Ryzen 7040 series) quirks:
    # (import <nixos-hardware/framework/16-inch/7040-amd>)
  ];

  options = {
    custom.steam.enable = lib.mkEnableOption "Steam and gaming support";
    custom.snap.enable = lib.mkEnableOption "Snap package support";
    hardware.framework.enable = lib.mkEnableOption "Framework 16-inch 7040 AMD support";  # Placeholder if needed
    hardware.fw-fanctrl.enable = lib.mkEnableOption "Framework fan control";
    custom.nvidia.enable = lib.mkEnableOption "NVIDIA GPU support";
  };

  config = {
    nixpkgs.overlays = [
      (final: prev: {
        unstable = import nixpkgs-unstable {
          system = prev.system;
          config.allowUnfree = true;
        };
      })
    ];

    nixpkgs.config.allowUnfree = true;

    # Custom Ollama service with ROCm and gfx override for Framework 7040/780M (gfx1103 -> treat as gfx1102)
    services.ollamaAgentic = {
      enable = true;
      preset = "default";
      acceleration = "rocm";
      advanced.rocm.gfxVersionOverride = "11.0.2";
        extraEnv = {
      WEBUI_SECRET_KEY = "your-super-secret-key-here-keep-it-long-and-random";
    };
    };

    # Alternatively, if using standard Ollama module:
    # services.ollama = {
    #   enable = true;
    #   acceleration = "rocm";
    #   rocmOverrideGfx = "11.0.2";
    # };

    custom.steam.enable = true;
    custom.snap.enable = false;
    hardware.fw-fanctrl.enable = true;  # Enables the official fw-fanctrl service (available since 25.11)
    custom.nvidia.enable = false;

    boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;
    boot.kernelPackages = pkgs.linuxPackages_latest;  # Stable latest; use cachyos if preferred

    boot.kernelParams = lib.mkIf (!config.custom.nvidia.enable) [
      "amdgpu.abmlevel=0"
      "amdgpu.sg_display=0"
      "amdgpu.exp_hw_support=1"
    ];
    boot.initrd.kernelModules = lib.mkIf (!config.custom.nvidia.enable) [ "amdgpu" ];
    boot.kernelModules = [ "amdgpu" "v4l2loopback" ];
    boot.extraModulePackages = [ config.boot.kernelPackages.v4l2loopback ];
    boot.extraModprobeConfig = ''
      options v4l2loopback devices=1 video_nr=10 card_label="Virtual Cam" exclusive_caps=1
    '';

    services.displayManager.sddm = {
      enable = true;
      wayland.enable = false;  # X11 for stability
    };
    services.displayManager.defaultSession = "hyprland";
    services.xserver.enable = true;
    services.xserver.videoDrivers = if config.custom.nvidia.enable then [ "nvidia" ] else [ "amdgpu" ];
    services.xserver.desktopManager.cinnamon.enable = true;
    services.xserver.windowManager.dwm.enable = true;
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

    networking.hostName = "nixos";
    networking.networkmanager.enable = true;
    networking.firewall.enable = true;

    hardware.bluetooth.enable = true;
    hardware.bluetooth.powerOnBoot = true;
    hardware.enableRedistributableFirmware = true;
    powerManagement.cpuFreqGovernor = "performance";

    hardware.graphics = lib.mkMerge [
      {
        enable = true;
        enable32Bit = true;
        package = pkgs.mesa;
      }
      (lib.mkIf config.custom.nvidia.enable {
        extraPackages = with pkgs; [ vaapiVdpau libvdpau-va-gl nvidia-vaapi-driver ];
      })
      (lib.mkIf (!config.custom.nvidia.enable) {
        extraPackages = with pkgs; [
          amdvlk
          vaapiVdpau
          libvdpau-va-gl
          rocmPackages.clr
          rocmPackages.clr.icd
        ];
        extraPackages32 = with pkgs.pkgsi686Linux; [ amdvlk ];
      })
    ];

    hardware.nvidia = lib.mkIf config.custom.nvidia.enable {
      modesetting.enable = true;
      powerManagement.enable = false;
      powerManagement.finegrained = false;
      open = false;
      nvidiaSettings = true;
      package = config.boot.kernelPackages.nvidiaPackages.stable;
    };

    time.timeZone = "America/Los_Angeles";
    i18n.defaultLocale = "en_US.UTF-8";
    i18n.extraLocaleSettings = {
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

    services.libinput.enable = true;
    services.acpid.enable = true;
    services.printing.enable = true;

    security.rtkit.enable = true;
    services.pipewire = {
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

    services.udisks2.enable = true;
    services.gvfs.enable = true;
    security.polkit.enable = true;
    services.power-profiles-daemon.enable = true;
    services.fwupd.enable = true;
    environment.etc."fwupd/fwupd.conf".text = lib.mkForce ''
      [fwupd]
      UpdateOnBoot=true
    '';

    services.fprintd.enable = true;
    security.pam.services = {
      login.fprintAuth = true;
      sudo.fprintAuth = true;
    };

    security.apparmor.enable = true;

    virtualisation.docker.enable = true;

    programs.wireshark.enable = true;

    users.users.asher = {
      isNormalUser = true;
      description = "Asher";
      extraGroups = [ "networkmanager" "wheel" "docker" "wireshark" "disk" ];
      shell = pkgs.bash;
      packages = with pkgs; [
        (writeShellScriptBin "install-quicklisp" ''
          curl -o /tmp/quicklisp.lisp https://beta.quicklisp.org/quicklisp.lisp
          ${pkgs.sbcl}/bin/sbcl --load /tmp/quicklisp.lisp --eval '(quicklisp-quickstart:install)' --quit
        '')
      ];
    };

    environment.systemPackages = with pkgs; [
      vim neovim-unwrapped neovim-qt emacs docker git git-lfs gh htop nvme-cli lm_sensors s-tui stress dmidecode util-linux gparted usbutils
      (python3Full.withPackages (ps: with ps; [
        pip virtualenv cryptography pycryptodome grpcio grpcio-tools protobuf numpy matplotlib python-snappy skidl
      ]))
      wireshark tcpdump nmap netcat
      cmake gcc gnumake ninja rustc cargo go openssl gnutls pkgconf snappy
      ardour audacity ffmpeg-full jack2 qjackctl libpulseaudio pkgsi686Linux.libpulseaudio pavucontrol guitarix faust faustlive
      qemu virt-manager docker-compose docker-buildx
      vulkan-tools vulkan-loader vulkan-validation-layers libva-utils
      dhewm3 darkradiant r2modman slade srb2 protonup-qt beyond-all-reason doomseeker chocolate-doom rbdoom quakespasm vkquake TrenchBroom godot Quake3e retroarch-free
      brave vlc pandoc kdePackages.okular obs-studio firefox thunderbird
      blueberry legcord vesktop font-awesome fastfetch gnugrep kitty wofi waybar hyprpaper brightnessctl zip unzip obsidian
      gimp kdePackages.kdenlive inkscape blender libreoffice krita synfigstudio
      xfce.thunar xfce.thunar-volman gvfs udiskie polkit_gnome framework-tool
      wl-clipboard grim slurp v4l-utils
      mininet ollama opencode open-webui
      unstable.openvscode-server
      (perl.withPackages (ps: with ps; [ JSON GetoptLong CursesUI ModulePluggable Appcpanminus ]))
      (sbcl.withPackages (ps: with ps; [
        cffi cl-ppcre cl-json cl-csv usocket bordeaux-threads log4cl trivial-backtrace cl-store hunchensocket fiveam cl-dot cserial-port
        cl-lorawan cl-lsquic cl-can cl-sctp cl-zigbee
      ]))
      libserialport can-utils lksctp-tools cjson ncurses libuuid kicad graphviz mako openscad freecad
      nextflow emboss blast lammps gromacs snakemake librecad qcad sweethome3d sdrpp natron xnec2c eliza systemctl-tui
      xorg.xinit unetbootin popsicle gnome-disk-utility zenity
    ] ++ lib.optionals config.custom.steam.enable [
      steam steam-run linuxConsoleTools lutris wineWowPackages.stable
    ];

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

    environment.etc."jack/conf.xml".text = ''
      <?xml version="1.0"?>
      <jack>
        <engine>
          <param name="driver" value="alsa"/>
          <param name="realtime" value="true"/>
        </engine>
      </jack>
    '';

    environment.etc."hypr/hyprland.conf".text = ''
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

    environment.sessionVariables = {
      QT_QPA_PLATFORM = "wayland;xcb";
      NIXOS_OZONE_WL = "1";
    };

    services.logind.extraConfig = ''
      HandleLidSwitch=ignore
      HandleLidSwitchExternalPower=ignore
      HandleLidSwitchDocked=ignore
    '';

    environment.etc."hypr/lid.sh" = {
      text = ''
        #!/usr/bin/env bash
        hyprctl keyword monitor "eDP-2,disable"  # Always disable laptop screen on lid close
        if [[ $1 == "open" ]]; then
          hyprctl keyword monitor "eDP-2,2560x1600@165,auto,1"
        fi
      '';
      mode = "0755";
    };

    environment.etc."hypr/toggle_clamshell.sh" = {
      text = ''
        #!/usr/bin/env bash
        INTERNAL="eDP-2"
        if [[ "$(hyprctl monitors)" =~ DP- ]]; then
          if hyprctl monitors | grep -q "$INTERNAL" && ! hyprctl monitors | grep -q "$INTERNAL.*(disabled)"; then
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

    # Optional: Quicklisp installer service and GC timer from first config
    # (Omitted here for brevity; add if needed)

    system.stateVersion = "25.11";
  };
}

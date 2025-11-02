{ config, pkgs, lib, nixpkgs-unstable, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./hydramesh.nix
    ./hydramesh/streamdb/flake.nix
  ];

  options = {
    custom.steam.enable = lib.mkEnableOption "Steam and gaming support";
    custom.snap.enable = lib.mkEnableOption "Snap package support";
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

    custom.steam.enable = true;
    custom.snap.enable = false;

    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;
    boot.kernelPackages = pkgs.linuxPackages_latest;
    boot.kernelParams = [
      "amdgpu.abmlevel=0"
      "amdgpu.sg_display=0"
      "amdgpu.exp_hw_support=1"
    ];
    boot.initrd.kernelModules = [ "amdgpu" ];
    boot.kernelModules = [ "amdgpu" "v4l2loopback" ];
    boot.extraModulePackages = [ config.boot.kernelPackages.v4l2loopback ];
    boot.extraModprobeConfig = ''
      options v4l2loopback devices=1 video_nr=10 card_label="Virtual Cam" exclusive_caps=1
    '';

    services.displayManager.sddm = {
      enable = true;
      wayland.enable = true;
    };
    services.displayManager.defaultSession = "hyprland";
    services.xserver.enable = true;
    services.xserver.videoDrivers = [ "amdgpu" ];
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
    networking.firewall.enable = true;  # System-wide firewall for added security

    hardware.bluetooth.enable = true;
    hardware.bluetooth.powerOnBoot = true;
    hardware.enableRedistributableFirmware = true;
    powerManagement.cpuFreqGovernor = "performance";

    hardware.graphics = {
      enable = true;
      enable32Bit = true;
      package = pkgs.mesa;
      extraPackages = with pkgs; [
        amdvlk
        vaapiVdpau
        libvdpau-va-gl
        rocmPackages.clr.icd
      ];
      extraPackages32 = with pkgs.pkgsi686Linux; [
        amdvlk
      ];
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

    security.apparmor.enable = true;  # Enable AppArmor system-wide

    virtualisation.docker.enable = true;

    programs.wireshark.enable = true;

    services.snap.enable = lib.mkIf config.custom.snap.enable true;

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

    systemd.user.services.quicklisp-install = {
      description = "Install Quicklisp for D-LISP";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.writeShellScriptBin "install-quicklisp" ''
          curl -o /tmp/quicklisp.lisp https://beta.quicklisp.org/quicklisp.lisp
          ${pkgs.sbcl}/bin/sbcl --load /tmp/quicklisp.lisp --eval '(quicklisp-quickstart:install)' --quit
        ''}/bin/install-quicklisp";
      };
    };

    environment.systemPackages = with pkgs; [
      vim
      docker
      git
      git-lfs
      gh
      htop
      nvme-cli
      lm_sensors
      s-tui
      stress
      dmidecode
      util-linux
      gparted
      usbutils
      (python3Full.withPackages (ps: with ps; [
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
      ]))
      wireshark
      tcpdump
      nmap
      netcat
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
      ardour
      audacity
      ffmpeg-full
      jack2
      qjackctl
      libpulseaudio
      pkgsi686Linux.libpulseaudio
      pavucontrol
      guitarix
      qemu
      virt-manager
      docker-compose
      docker-buildx
      vulkan-tools
      vulkan-loader
      vulkan-validation-layers
      libva-utils
      brave
      vlc
      pandoc
      kdePackages.okular
      obs-studio
      firefox
      thunderbird
      blueberry
      vesktop
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
      gimp
      kdePackages.kdenlive
      inkscape
      blender
      libreoffice
      krita
      xfce.thunar
      xfce.thunar-volman
      gvfs
      udiskie
      polkit_gnome
      framework-tool
      wl-clipboard
      grim
      slurp
      v4l-utils
      mininet
      unstable.openvscode-server
      (perl.withPackages (ps: with ps; [
        JSON
        GetoptLong
        CursesUI
        ModulePluggable
        Appcpanminus
      ]))
      (sbcl.withPackages (ps: with ps; [
        cffi
        cl-ppcre
        cl-json
        cl-csv
        usocket
        bordeaux-threads
        log4cl
        trivial-backtrace
        cl-store
        hunchensocket
        fiveam
        cl-dot
        cserial-port
        cl-lorawan
        cl-lsquic
        cl-can
        cl-sctp
        cl-zigbee
      ]))
      libserialport
      can-utils
      lksctp-tools
      cjson
      ncurses
      libuuid
      kicad
      graphviz
      mako
      openscad
      freecad
      nextflow
      emboss
      blast
      lammps
      gromacs
      snakemake
      librecad
      qcad
      sweethome3d
      sdrpp
      natron
      xnec2c
      eliza
      systemctl-tui
      xorg.xinit
      unetbootin
      popsicle
      gnome-disk-utility
      zenity
    ] ++ lib.optionals config.custom.steam.enable [
      steam
      steam-run
      linuxConsoleTools
      lutris
      wineWowPackages.stable
      dhewm3 darkradiant r2modman
      slade srb2
      protonup-qt beyond-all-reason
      doomseeker chocolate-doom rbdoom
      quakespasm vkquake TrenchBroom
      godot Quake3e retroarch-free
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

    environment.sessionVariables = {
      QT_QPA_PLATFORM = "wayland;xcb";
      NIXOS_OZONE_WL = "1";
    };

    services.logind.extraConfig = ''
      HandleLidSwitch=ignore
      HandleLidSwitchExternalPower=ignore
      HandleLidSwitchDocked=ignore
    '';

    system.stateVersion = "25.05";
  };
}

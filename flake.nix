# configuration.nix
{ config, pkgs, lib, nixpkgs-unstable, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./agentic-local-ai.nix   # This likely defines the custom services.ollamaAgentic module
    ./modules/archibaldos-dsp-vm.nix  # Already included via flake, but safe to keep
  ];

  options = {
    custom.steam.enable = lib.mkEnableOption "Steam and gaming support";
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

    # Custom Ollama service (likely defined in agentic-local-ai.nix)
    services.ollamaAgentic = {
      enable = true;
      preset = "default";
      acceleration = "rocm";
    };

    custom.steam.enable = true;

    boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

    boot.loader.systemd-boot.enable = true;
    boot.loader.efi.canTouchEfiVariables = true;

    # Use CachyOS kernel from the added module (optional; fallback to latest)
    # boot.kernelPackages = pkgs.linuxPackages_cachyos;  # Uncomment to force CachyOS kernel
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
      wayland.enable = false;  # Keep X11 for stability
    };
    services.displayManager.defaultSession = "hyprland";
    services.xserver.enable = true;
    services.xserver.videoDrivers = [ "amdgpu" ];
    services.xserver.desktopManager.cinnamon.enable = true;
    services.xserver.windowManager.dwm.enable = true;
    programs.hyprland = {
      enable = true;
      xwayland.enable = true;
      package = pkgs.hyprland;  # Stable Hyprland
    };
    systemd.defaultUnit = lib.mkForce "graphical.target";

    xdg.portal = {
      enable = true;
      extraPortals = [ pkgs.xdg-desktop-portal-gtk ];
      config.common.default = "*";
    };

    networking.hostName = "nixos";
    networking.networkmanager.enable = true;

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
        rocmPackages.clr
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
      extraConfig = {
        pipewire."90-custom" = {
          "default.clock.quantum" = 1024;
          "default.clock.min-quantum" = 512;
          "default.clock.max-quantum" = 2048;
        };
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

    # Quicklisp installation services remain unchanged...

    systemd.timers.nix-gc-generations = { ... };
    systemd.services.nix-gc-generations = { ... };

    environment.systemPackages = with pkgs; [
      # All packages from the original configuration.nix...
    ] ++ lib.optionals config.custom.steam.enable [
      steam
      steam-run
      linuxConsoleTools
      lutris
      wineWowPackages.stable
    ];

    programs.steam = lib.mkIf config.custom.steam.enable { ... };
    hardware.steam-hardware = lib.mkIf config.custom.steam.enable { ... };
    programs.gamemode = lib.mkIf config.custom.steam.enable { ... };

    # Hyprland config, session variables, lid handling scripts, etc. remain unchanged...

    system.stateVersion = "25.11";
  };
}

{
  description = "Determinate NixOS Setup for R&D with Multiple Kernels, Desktops, and DeMoD Communication Framework";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    determinate.url = "https://flakehub.com/f/DeterminateSystems/determinate/*";
    nixos-hardware.url = "github:NixOS/nixos-hardware";
    fw-fanctrl.url = "github:TamtamHero/fw-fanctrl/packaging/nix";
    demod-ip-blocker.url = "git+https://github.com/ALH477/DeMoD-IP-Blocker.git";
  };

  outputs = { self, nixpkgs, nixpkgs-unstable, determinate, nixos-hardware, fw-fanctrl, demod-ip-blocker, ... }@inputs:
  let
    system = "x86_64-linux";
    lib = nixpkgs.lib;
  in {
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      inherit system;
      specialArgs = { inherit inputs nixpkgs-unstable lib; };
      modules = [
        determinate.nixosModules.default
        nixos-hardware.nixosModules.framework-16-7040-amd
        fw-fanctrl.nixosModules.default
        demod-ip-blocker.nixosModules.default
        ./hardware-configuration.nix
        ./modules/agentic-local-ai.nix
        ./modules/archibaldos-dsp-vm.nix
        ({ config, pkgs, lib, nixpkgs-unstable, ... }: {
          nixpkgs.overlays = [
            (final: prev: {
              unstable = import nixpkgs-unstable {
                system = prev.system;
                config.allowUnfree = true;
              };
            })
          ];
          hardware.framework.enable = true;
          hardware.fw-fanctrl.enable = true;
        })
        ({ config, pkgs, lib, inputs, nixpkgs-unstable, ... }: {
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

            # Custom Ollama service
            services.ollamaAgentic = {
              enable = true;
              preset = "default";
              acceleration = "rocm";
            };

            # DeMoD IP Blocker Configuration
            services.demod-ip-blocker = {
              enable = true;
              updateInterval = "24h"; # Background refresh for long uptimes
            };

            custom.steam.enable = true;

            boot.binfmt.emulatedSystems = [ "aarch64-linux" ];

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
              wayland.enable = false; # Keep X11 for stability
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
        })
      ];
    };
  };
}

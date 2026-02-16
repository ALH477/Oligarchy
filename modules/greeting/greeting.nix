flake: { config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.oligarchyGreeting;
  
  # Get the package from the flake
  oligarchy-greeting = flake.packages.${pkgs.system}.default or null;
  
  # Generate config file
  configFile = pkgs.writeText "oligarchy-greeting.json" (builtins.toJSON {
    ascii_art = cfg.asciiArt;
    welcome_message = cfg.welcomeMessage;
    show_system_info = cfg.showSystemInfo;
    custom_links = cfg.customLinks;
    tips = cfg.tips;
    images = {
      banner = {
        path = "/etc/oligarchy/banner.jpg";
        enabled = cfg.images.banner.enabled;
        position = "header";
        aspect_ratio = "16:9";
        max_height = cfg.images.banner.maxHeight;
      };
      logo = {
        path = "/etc/oligarchy/logo.png";
        enabled = cfg.images.logo.enabled;
        position = "sidebar";
        aspect_ratio = "1:1";
        max_size = cfg.images.logo.maxSize;
      };
    };
    layout = cfg.layout;
    fallback_to_ascii = cfg.fallbackToAscii;
    tui = {
      enabled = cfg.tui.enable;
      show_launcher = cfg.tui.showLauncher;
      launch_command = cfg.tui.launchCommand;
    };
  });
  
in {
  options.services.oligarchyGreeting = {
    enable = mkEnableOption "Oligarchy welcome greeting on login";
    
    asciiArt = mkOption {
      type = types.str;
      default = ''
    .d88b. 8    888 .d88b     db    888b. .d88b 8   8 Yb  dP
    8P  Y8 8     8  8P www   dPYb   8  .8 8P    8www8  YbdP
    8b  d8 8     8  8b  d8  dPwwYb  8wwK' 8b    8   8   YP
    `Y88P' 8888 888 `Y88P' dP    Yb 8  Yb `Y88P 8   8   88
      '';
      description = "ASCII art to display when images are not available";
    };
    
    welcomeMessage = mkOption {
      type = types.str;
      default = "Welcome to Oligarchy — The War Machine";
      description = "Welcome message displayed";
    };
    
    showSystemInfo = mkOption {
      type = types.bool;
      default = true;
      description = "Show system information";
    };
    
    customLinks = mkOption {
      type = types.listOf (types.submodule {
        options = {
          name = mkOption { 
            type = types.str; 
            description = "Display name for the link";
          };
          url = mkOption { 
            type = types.str; 
            description = "URL for the link";
          };
        };
      });
      default = [
        { name = "Documentation"; url = "https://github.com/ALH477/Oligarchy"; }
        { name = "NixOS Manual"; url = "https://nixos.org/manual/nixos/stable/"; }
      ];
      description = "Custom quick links to display";
    };
    
    tips = mkOption {
      type = types.listOf types.str;
      default = [
        "Press Super+L to lock screen"
        "Use 'nix flake update' to update system"
        "Run 'nix-collect-garbage -d' to clean old generations"
      ];
      description = "Tips to display randomly";
    };
    
    images = {
      banner = {
        enabled = mkOption {
          type = types.bool;
          default = true;
          description = "Enable banner image (16:9 visual)";
        };
        
        maxHeight = mkOption {
          type = types.int;
          default = 20;
          description = "Maximum height in terminal rows";
        };
      };
      
      logo = {
        enabled = mkOption {
          type = types.bool;
          default = true;
          description = "Enable logo image (square icon)";
        };
        
        maxSize = mkOption {
          type = types.int;
          default = 15;
          description = "Maximum size in terminal columns/rows";
        };
      };
    };
    
    layout = mkOption {
      type = types.enum [ "adaptive" "banner_only" "logo_only" "both" "ascii_only" ];
      default = "adaptive";
      description = ''
        Image layout mode:
        - adaptive: Show banner for wide terminals, logo for narrow
        - banner_only: Always show banner (16:9 visual)
        - logo_only: Always show logo (square icon)
        - both: Show both banner and logo
        - ascii_only: Disable images, use ASCII art
      '';
    };
    
    fallbackToAscii = mkOption {
      type = types.bool;
      default = true;
      description = "Fall back to ASCII art if images not supported";
    };
    
    tui = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable interactive TUI launcher";
      };
      
      showLauncher = mkOption {
        type = types.bool;
        default = true;
        description = "Show TUI launcher prompt after greeting";
      };
      
      launchCommand = mkOption {
        type = types.str;
        default = "hyprctl dispatch exec kitty";
        description = "Command to launch when user presses key";
      };
    };
  };
  
  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = oligarchy-greeting != null;
        message = "oligarchy-greeting package is required but not available";
      }
    ];
    
    # Install the package
    environment.systemPackages = [ oligarchy-greeting ];
    
    # Create directories and install images
    environment.etc."oligarchy".source = pkgs.runCommand "oligarchy-assets" {} ''
      mkdir -p $out
      
      # Copy images if they exist in the source
      if [ -f ${../../assets/demod-logo.png} ]; then
        cp ${../../assets/demod-logo.png} $out/logo.png
      fi
      
      if [ -f ${../../Untitled.jpg} ]; then
        cp ${../../Untitled.jpg} $out/banner.jpg
      fi
      
      # Install config
      cp ${configFile} $out/greeting.json
    '';
    
    # Add greeting to bash login
    programs.bash.loginShellInit = ''
      if [ -z "$SSH_CONNECTION" ] && [ -z "$TMUX" ]; then
        ${oligarchy-greeting}/bin/show-greeting --config /etc/oligarchy/greeting.json
      fi
    '';
    
    # Create shell alias
    environment.shellAliases = {
      "welcome-tui" = "${oligarchy-greeting}/bin/welcome-tui /etc/oligarchy/greeting.json";
      "show-greeting" = "${oligarchy-greeting}/bin/show-greeting --config /etc/oligarchy/greeting.json";
    };
  };
}

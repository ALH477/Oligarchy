flake: { config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.oligarchyGreeting;
  
  welcome-tui = flake.packages.${pkgs.system}.welcome-tui or null;
  
  tuiConfigFile = pkgs.writeText "welcome-tui-config.json" (builtins.toJSON {
    links = map (l: [ l.name l.url ]) cfg.customLinks;
    tips = cfg.tips;
    welcome_message = cfg.welcomeMessage;
    ascii_art = cfg.asciiArt;
  });
  
  greetingScript = let
    scriptContent = ''
      #!/bin/bash
      
      show_header() {
      ${optionalString cfg.showHeader ''
        cat << 'EOFART'
      ${cfg.asciiArt}
      EOFART
      ''}
      }
      
      show_welcome() {
      ${optionalString (cfg.welcomeMessage != "") ''
        echo "${cfg.welcomeMessage}"
        echo ""
      ''}
      }
      
      show_system_info() {
      ${optionalString cfg.showSystemInfo ''
        echo "System Information:"
        echo "  OS: $(cat /etc/os-release | grep PRETTY_NAME | cut -d'"' -f2)"
        echo "  Kernel: $(uname -r)"
        echo "  Hostname: $(hostname)"
        echo ""
      ''}
      }
      
      show_links() {
      ${optionalString (cfg.customLinks != []) ''
        echo "Quick Links:"
      ${concatMapStringsSep "\n" (link: ''
        echo "  - ${link.name}: ${link.url}"
      '') cfg.customLinks}
        echo ""
      ''}
      }
      
      show_launcher() {
      ${optionalString cfg.tui.showLauncher ''
        echo "Press any key to launch the War Room TUI, or wait 3 seconds..."
        if read -t 3 -n 1; then
      ${optionalString (welcome-tui != null) ''
          ${cfg.tui.launchCommand} ${tuiConfigFile}
      ''}
        fi
      ''}
      }
      
      show_header
      show_welcome
      show_system_info
      show_links
      show_launcher
    '';
  in pkgs.writeScriptBin "show-greeting" scriptContent;
in {
  options.services.oligarchyGreeting = {
    enable = mkEnableOption "user greeting on login";
    
    showHeader = mkOption {
      type = types.bool;
      default = true;
      description = "Show ASCII art header";
    };
    
    asciiArt = mkOption {
      type = types.str;
      default = ''
    .d88b. 8    888 .d88b     db    888b. .d88b 8   8 Yb  dP
    8P  Y8 8     8  8P www   dPYb   8  .8 8P    8www8  YbdP
    8b  d8 8     8  8b  d8  dPwwYb  8wwK' 8b    8   8   YP
    `Y88P' 8888 888 `Y88P' dP    Yb 8  Yb `Y88P 8   8   88
      '';
    };
    
    welcomeMessage = mkOption {
      type = types.str;
      default = "Welcome to Oligarchy";
      description = "Welcome message displayed after ASCII art";
    };
    
    showSystemInfo = mkOption {
      type = types.bool;
      default = true;
      description = "Show system information";
    };
    
    customLinks = mkOption {
      type = types.listOf (types.submodule {
        options = {
          name = mkOption { type = types.str; };
          url = mkOption { type = types.str; };
        };
      });
      default = [];
      description = "Custom quick links to display";
    };
    
    tips = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Tips to display randomly";
    };
    
    customContent = mkOption {
      type = types.str;
      default = "";
      description = "Additional custom content to display";
    };
    
    tui = {
      enable = mkEnableOption "launch War Room TUI";
      
      showLauncher = mkOption {
        type = types.bool;
        default = true;
        description = "Show launcher prompt";
      };
      
      launchCommand = mkOption {
        type = types.str;
        default = "welcome-tui";
        description = "Command to launch the TUI";
      };
    };
  };
  
  config = mkIf cfg.enable {
    environment.systemPackages = [ greetingScript ]
      ++ optional (welcome-tui != null) welcome-tui;
    
    programs.bash.loginShellInit = ''
      if [ -z "$SSH_CONNECTION" ] && [ -z "$TMUX" ]; then
        show-greeting
      fi
    '';
  };
}

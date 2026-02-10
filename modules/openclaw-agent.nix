{ config, lib, pkgs, inputs, ... }:

with lib;

let
  cfg = config.services.openclaw-agent;
  
  # Import openclaw overlay
  openclawPkgs = import pkgs.path {
    inherit (pkgs) system;
    overlays = [ inputs.nix-openclaw.overlays.default ];
  };

  # Document files
  documentsDir = ./openclaw-documents;
  
  # Popular plugins for CLI selection
  popularPlugins = [
    { name = "summarize"; source = "github:openclaw/summarize"; description = "Text summarization plugin"; }
    { name = "oracle"; source = "github:openclaw/oracle"; description = "Knowledge and research plugin"; }
    { name = "peekaboo"; source = "github:openclaw/peekaboo"; description = "System monitoring plugin"; }
    { name = "poltergeist"; source = "github:openclaw/poltergeist"; description = "File operations plugin"; }
    { name = "sag"; source = "github:openclaw/sag"; description = "System administration plugin"; }
  ];

  # OpenClaw configuration generation
  openclawConfig = {
    gateway = {
      mode = "local";
      auth = {
        token = cfg.gatewayToken;
      };
    };
    
    instances.default = {
      enable = true;
      plugins = cfg.plugins;
    };
  };

  # Generate OpenClaw config file
  configFile = pkgs.writeText "openclaw-config.yaml" (builtins.toJSON openclawConfig);

  # Plugin selection script
  pluginSelectorScript = pkgs.writeShellScriptBin "openclaw-select-plugin" ''
    #!/usr/bin/env bash
    set -euo pipefail

    # Colors
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m'

    error() { echo -e "''${RED}[ERROR]''${NC} $*" >&2; }
    success() { echo -e "''${GREEN}[OK]''${NC} $*"; }
    warn() { echo -e "''${YELLOW}[WARN]''${NC} $*"; }
    info() { echo -e "''${BLUE}[INFO]''${NC} $*"; }
    
    echo -e "''${CYAN}=== OpenClaw Plugin Selection ===''${NC}"
    echo ""

    PS3="Select a plugin to add (or press Enter to finish): "
    
    plugins=(
      ${concatMapStringsSep "\n    " (p: ''"${p.name} - ${p.description}"'') popularPlugins}
      "Done - Finish selection"
    )
    
    selected_plugins=()
    
    select_option() {
      local prompt="$1"
      shift
      local options=("$@")
      
      select opt in "''${options[@]}"; do
        if [[ -n "$opt" ]]; then
          echo "$opt"
          return 0
        else
          echo "Invalid selection. Please try again."
        fi
      done
    }
    
    while true; do
      echo -e "''${CYAN}Available plugins:''${NC}"
      selection=$(select_option "$PS3" "''${plugins[@]}")
      
      case "$selection" in
        "Done - Finish selection")
          break
          ;;
        "summarize - Text summarization plugin"|"oracle - Knowledge and research plugin"|"peekaboo - System monitoring plugin"|"poltergeist - File operations plugin"|"sag - System administration plugin")
          plugin_name=$(echo "$selection" | cut -d' ' -f1)
          if [[ " ''${selected_plugins[@]} " =~ " ''${plugin_name} " ]]; then
            warn "Plugin $plugin_name already selected"
          else
            selected_plugins+=("$plugin_name")
            success "Added plugin: $plugin_name"
          fi
          ;;
        *)
          error "Invalid selection"
          ;;
      esac
      echo ""
    done
    
    if [[ ''${#selected_plugins[@]} -eq 0 ]]; then
      warn "No plugins selected"
      exit 0
    fi
    
    echo ""
    echo -e "''${CYAN}=== Selected Plugins ===''${NC}"
    printf ' - %s\n' "''${selected_plugins[@]}"
    echo ""
    
    # Generate plugin configuration
    echo "# OpenClaw Plugin Configuration"
    echo "plugins = ["
    for plugin in "''${selected_plugins[@]}"; do
      case "$plugin" in
        "summarize")
          echo "  { source = \"github:openclaw/summarize\"; }"
          ;;
        "oracle")
          echo "  { source = \"github:openclaw/oracle\"; }"
          ;;
        "peekaboo")
          echo "  { source = \"github:openclaw/peekaboo\"; }"
          ;;
        "poltergeist")
          echo "  { source = \"github:openclaw/poltergeist\"; }"
          ;;
        "sag")
          echo "  { source = \"github:openclaw/sag\"; }"
          ;;
      esac
    done
    echo "];"
    echo ""
    success "Plugin configuration generated for your configuration.nix"
  '';

in
{
  options.services.openclaw-agent = {
    enable = mkEnableOption "OpenClaw agent service";

    user = mkOption {
      type = types.str;
      default = "blipply";
      description = "User to run OpenClaw as";
    };

    homeDirectory = mkOption {
      type = types.str;
      default = "/home/${cfg.user}";
      description = "Home directory for OpenClaw user";
    };

    gatewayToken = mkOption {
      type = types.str;
      default = "openclaw-gateway-token-${builtins.substring 0 8 (builtins.hashString "sha256" "openclaw")}";
      description = "Authentication token for gateway";
    };

    documents = mkOption {
      type = types.path;
      default = documentsDir;
      description = "Path to OpenClaw documents directory";
    };

    plugins = mkOption {
      type = types.listOf types.attrs;
      default = [];
      description = "List of OpenClaw plugins";
      example = [
        { source = "github:acme/hello-world"; }
      ];
    };

    lanAccess = mkOption {
      type = types.bool;
      default = false;
      description = "Allow LAN access to OpenClaw services";
    };

    bindAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Bind address for OpenClaw gateway";
    };
  };

  config = mkIf cfg.enable {
    # Add nix-openclaw overlay
    nixpkgs.overlays = [ inputs.nix-openclaw.overlays.default ];

    # Create blipply user with proper permissions
    users.users.${cfg.user} = {
      isNormalUser = true;
      description = "OpenClaw AI Agent Service User";
      createHome = true;
      home = cfg.homeDirectory;
      group = "${cfg.user}";
      extraGroups = [ "users" ];
      linger = true;  # Enable user services to start at boot
    };

    users.groups.${cfg.user} = {};

    # Ensure required packages are available
    environment.systemPackages = with pkgs; [
      openclawPkgs.openclaw
      openclawPkgs.openclaw-gateway
      pluginSelectorScript
    ];

    # Create directories and setup environment
    systemd.tmpfiles.rules = [
      "d ${cfg.documents} 0755 ${cfg.user} ${cfg.user} -"
      "d ${cfg.homeDirectory}/.openclaw 0755 ${cfg.user} ${cfg.user} -"
      "L+ ${cfg.homeDirectory}/.openclaw/workspace - - - - ${cfg.documents}"
      "d ${cfg.homeDirectory}/.config/openclaw 0755 ${cfg.user} ${cfg.user} -"
      "C ${cfg.homeDirectory}/.config/openclaw/config.yaml 0644 ${cfg.user} ${cfg.user} - ${configFile}"
    ];

    # OpenClaw gateway systemd user service
    systemd.user.services.openclaw-gateway = {
      description = "OpenClaw AI Gateway";
      wantedBy = [ "default.target" ];
      after = [ "network.target" ];
      
      serviceConfig = {
        Type = "simple";
        ExecStart = "${openclawPkgs.openclaw-gateway}/bin/openclaw-gateway --config ${cfg.homeDirectory}/.config/openclaw/config.yaml";
        Restart = "on-failure";
        RestartSec = "5s";
        User = cfg.user;
        Group = cfg.user;
        WorkingDirectory = cfg.homeDirectory;
        
        # Security settings
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        ReadWritePaths = [ cfg.homeDirectory "/tmp" ];
        
        # Resource limits
        MemoryMax = "1G";
        CPUQuota = "50%";
      };
      
      # Service environment
      environment = {
        OPENCLAW_CONFIG_PATH = "${cfg.homeDirectory}/.config/openclaw/config.yaml";
        OPENCLAW_WORKSPACE_PATH = "${cfg.homeDirectory}/.openclaw/workspace";
        OPENCLAW_LOG_LEVEL = "info";
      } // optionalAttrs cfg.lanAccess {
        OPENCLAW_BIND_ADDRESS = "0.0.0.0";
      };
    };

    # Update bind address based on LAN access setting
    services.openclaw-agent.bindAddress = mkIf cfg.lanAccess "0.0.0.0";

    # Shell aliases for management
    environment.shellAliases = {
      openclaw-status = "systemctl --user status openclaw-gateway";
      openclaw-logs = "journalctl --user -u openclaw-gateway -f";
      openclaw-restart = "systemctl --user restart openclaw-gateway";
      openclaw-select-plugin = "openclaw-select-plugin";
      openclaw-config = "cat ${cfg.homeDirectory}/.config/openclaw/config.yaml";
      openclaw-workspace = "cd ${cfg.homeDirectory}/.openclaw/workspace";
    };
  };
}
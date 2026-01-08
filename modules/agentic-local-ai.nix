{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.ollamaAgentic;
  userName = "asher";
  userHome = config.users.users.${userName}.home or "/home/${userName}";
  
  # Centralized paths
  paths = {
    base = "${userHome}/.config/ollama-agentic/ai-stack";
    ollama = "${userHome}/.ollama";
    state = "${userHome}/.config/ollama-agentic/ai-stack/.state";
  };

  # Preset configurations for different hardware profiles
  presetConfigs = {
    cpu-fallback = {
      shmSize = "8gb";
      numParallel = 1;
      maxLoadedModels = 2;
      keepAlive = "12h";
      maxQueue = 128;
      memoryPressure = "0.90";
    };
    
    default = {
      shmSize = "16gb";
      numParallel = 4;
      maxLoadedModels = 4;
      keepAlive = "24h";
      maxQueue = 512;
      memoryPressure = "0.85";
    };
    
    high-vram = {
      shmSize = "32gb";
      numParallel = 8;
      maxLoadedModels = 6;
      keepAlive = "48h";
      maxQueue = 1024;
      memoryPressure = "0.80";
    };
    
    rocm-multi = {
      shmSize = "48gb";
      numParallel = 12;
      maxLoadedModels = 8;
      keepAlive = "72h";
      maxQueue = 2048;
      memoryPressure = "0.75";
    };
    
    cuda = {
      shmSize = "48gb";
      numParallel = 12;
      maxLoadedModels = 8;
      keepAlive = "72h";
      maxQueue = 2048;
      memoryPressure = "0.75";
    };
    
    pewdiepie = {
      shmSize = "64gb";
      numParallel = 16;
      maxLoadedModels = 10;
      keepAlive = "72h";
      maxQueue = 2048;
      memoryPressure = "0.75";
    };
  };

  currentPreset = presetConfigs.${cfg.preset};

  # Determine acceleration method
  effectiveAcceleration =
    if cfg.acceleration != null then cfg.acceleration
    else if cfg.preset == "rocm-multi" then "rocm"
    else if cfg.preset == "cuda" then "cuda"
    else null;

  # Choose appropriate Docker image
  ollamaImage =
    if effectiveAcceleration == "rocm" then "ollama/ollama:rocm"
    else "ollama/ollama";

  # Build environment variables
  rocmEnvVars = optionalString (effectiveAcceleration == "rocm") ''
    ROCR_VISIBLE_DEVICES: "0"
    ${optionalString (cfg.advanced.rocm.gfxVersionOverride != null)
      ''HSA_OVERRIDE_GFX_VERSION: "${cfg.advanced.rocm.gfxVersionOverride}"''}
  '';

  # Generate docker-compose configuration
  dockerComposeYml = pkgs.writeText "docker-compose-agentic-ai.yml" ''
    services:
      ollama:
        image: ${ollamaImage}
        container_name: ollama
        restart: unless-stopped
        ipc: host
        shm_size: "${currentPreset.shmSize}"
        security_opt:
          - no-new-privileges:true
        
        ${optionalString (effectiveAcceleration == "rocm") ''
        devices:
          - "/dev/kfd:/dev/kfd"
          - "/dev/dri:/dev/dri"
        group_add:
          - video
        ''}
        
        ${optionalString (effectiveAcceleration == "cuda") ''
        deploy:
          resources:
            reservations:
              devices:
                - driver: nvidia
                  count: all
                  capabilities: [gpu]
            limits:
              memory: ${currentPreset.shmSize}
        ''}
        
        ${optionalString (effectiveAcceleration == "rocm") ''
        deploy:
          resources:
            limits:
              memory: ${currentPreset.shmSize}
        ''}
        
        volumes:
          - ${paths.ollama}:/root/.ollama
        
        ports:
          - "${cfg.network.ollamaBindAddress}:11434:11434"
        
        environment:
          OLLAMA_FLASH_ATTENTION: "1"
          OLLAMA_NUM_PARALLEL: "${toString currentPreset.numParallel}"
          OLLAMA_MAX_LOADED_MODELS: "${toString currentPreset.maxLoadedModels}"
          OLLAMA_KEEP_ALIVE: "${currentPreset.keepAlive}"
          OLLAMA_SCHED_SPREAD: "1"
          OLLAMA_KV_CACHE_TYPE: "q8_0"
          OLLAMA_MAX_QUEUE: "${toString currentPreset.maxQueue}"
          OLLAMA_MEMORY_PRESSURE_THRESHOLD: "${currentPreset.memoryPressure}"
          ${rocmEnvVars}
  '';

  # Management script for the AI stack
  aiStackScript = pkgs.writeShellScriptBin "ai-stack" ''
    #!/usr/bin/env bash
    set -euo pipefail

    # Colors for output
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'

    # Helper functions
    error() { echo -e "''${RED}[ERROR]''${NC} $*" >&2; }
    success() { echo -e "''${GREEN}[SUCCESS]''${NC} $*"; }
    warn() { echo -e "''${YELLOW}[WARN]''${NC} $*"; }
    info() { echo -e "''${BLUE}[INFO]''${NC} $*"; }

    # Verify user is in docker group
    if ! groups | grep -q docker; then
      error "User must be in 'docker' group."
      exit 1
    fi

    # Ensure directories exist with proper permissions
    mkdir -p "${paths.base}" "${paths.ollama}" "${paths.state}"
    chmod 700 "${paths.ollama}" "${paths.state}"

    COMPOSE_DIR="${paths.base}"
    COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
    cd "$COMPOSE_DIR"

    # Deploy or update docker-compose file
    deploy_compose() {
      if [ ! -f "$COMPOSE_FILE" ] || [ "${dockerComposeYml}" -nt "$COMPOSE_FILE" ]; then
        cp ${dockerComposeYml} "$COMPOSE_FILE"
        info "Docker Compose configuration updated"
      fi
    }

    # Command routing
    case "''${1:-}" in
      start|up)
        deploy_compose
        docker compose up -d
        success "Ollama running at http://${cfg.network.ollamaBindAddress}:11434"
        ;;
        
      stop|down)
        docker compose down
        success "Ollama stopped"
        ;;
        
      restart)
        docker compose down
        deploy_compose
        docker compose up -d
        success "Ollama restarted"
        ;;
        
      status)
        docker compose ps
        ;;
        
      logs)
        docker compose logs -f ollama
        ;;
        
      *)
        echo "Usage: ai-stack {start|stop|restart|status|logs}"
        exit 1
        ;;
    esac
  '';

in
{
  options.services.ollamaAgentic = {
    enable = mkEnableOption "Ollama local AI stack";

    preset = mkOption {
      type = types.enum [ "cpu-fallback" "default" "high-vram" "rocm-multi" "cuda" "pewdiepie" ];
      default = "default";
      description = "Hardware preset configuration for Ollama";
    };

    acceleration = mkOption {
      type = types.nullOr (types.enum [ "cuda" "rocm" ]);
      default = null;
      description = "GPU acceleration method (auto-detected from preset if not specified)";
    };

    network.ollamaBindAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Bind address for Ollama service (use 0.0.0.0 to expose to LAN)";
    };

    advanced.rocm.gfxVersionOverride = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Override HSA_OVERRIDE_GFX_VERSION for ROCm (e.g., '11.0.2')";
      example = "11.0.2";
    };
  };

  config = mkIf cfg.enable {
    virtualisation.docker.enable = true;

    # Add user to necessary groups
    users.users.${userName}.extraGroups = [ "docker" ] 
      ++ optionals (effectiveAcceleration == "rocm") [ "video" ];

    # Install required packages
    environment.systemPackages = with pkgs; [
      docker
      docker-compose
      aiStackScript
    ] ++ optionals (effectiveAcceleration == "rocm") [
      rocmPackages.rocm-smi
      rocmPackages.rocminfo
    ];

    # Setup directories on system activation
    system.activationScripts.aiAgentSetup = stringAfter [ "users" ] ''
      mkdir -p "${paths.base}" "${paths.ollama}" "${paths.state}"
      chown -R ${userName}:users "${paths.base}" "${paths.ollama}" "${paths.state}"
      chmod 700 "${paths.ollama}" "${paths.state}"
    '';

    # Open firewall port if exposing to LAN
    networking.firewall.allowedTCPPorts = 
      mkIf (cfg.network.ollamaBindAddress != "127.0.0.1") [ 11434 ];

    # Convenient shell aliases
    environment.shellAliases = {
      ai = "ai-stack";
      ollama-logs = "ai-stack logs";
    };
  };
}

{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.ollamaAgentic;
  userName = "asher";
  userHome = config.users.users.${userName}.home or "/home/${userName}";
  
  # Directory structure
  paths = {
    base = "${userHome}/.config/ollama-agentic";
    ollama = "${userHome}/.ollama";
    models = "${userHome}/.ollama/models";
    compose = "${userHome}/.config/ollama-agentic/compose";
  };

  # Hardware presets
  presets = {
    cpu-fallback = {
      shmSize = "8gb";
      numParallel = 1;
      maxLoadedModels = 2;
      keepAlive = "12h";
      maxQueue = 128;
      memoryPressure = "0.90";
      description = "CPU-only fallback mode";
    };
    
    default = {
      shmSize = "16gb";
      numParallel = 4;
      maxLoadedModels = 4;
      keepAlive = "24h";
      maxQueue = 512;
      memoryPressure = "0.85";
      description = "Default GPU configuration";
    };
    
    high-vram = {
      shmSize = "32gb";
      numParallel = 8;
      maxLoadedModels = 6;
      keepAlive = "48h";
      maxQueue = 1024;
      memoryPressure = "0.80";
      description = "High VRAM GPU (16GB+)";
    };
    
    rocm-multi = {
      shmSize = "48gb";
      numParallel = 12;
      maxLoadedModels = 8;
      keepAlive = "72h";
      maxQueue = 2048;
      memoryPressure = "0.75";
      description = "AMD ROCm multi-GPU";
    };
    
    cuda = {
      shmSize = "48gb";
      numParallel = 12;
      maxLoadedModels = 8;
      keepAlive = "72h";
      maxQueue = 2048;
      memoryPressure = "0.75";
      description = "NVIDIA CUDA configuration";
    };
    
    pewdiepie = {
      shmSize = "64gb";
      numParallel = 16;
      maxLoadedModels = 10;
      keepAlive = "72h";
      maxQueue = 2048;
      memoryPressure = "0.75";
      description = "Maximum performance (64GB+ RAM, 24GB+ VRAM)";
    };
  };

  currentPreset = presets.${cfg.preset};

  # Determine acceleration
  effectiveAcceleration =
    if cfg.acceleration != null then cfg.acceleration
    else if cfg.preset == "rocm-multi" then "rocm"
    else if cfg.preset == "cuda" then "cuda"
    else null;

  # Docker image selection
  ollamaImage =
    if effectiveAcceleration == "rocm" then "ollama/ollama:rocm"
    else "ollama/ollama:latest";

  # Generate docker-compose.yml
  dockerComposeContent = ''
    version: "3.9"
    
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
        ''}
        
        volumes:
          - ${paths.ollama}:/root/.ollama
        
        ports:
          - "${cfg.network.bindAddress}:11434:11434"
        
        environment:
          OLLAMA_FLASH_ATTENTION: "1"
          OLLAMA_NUM_PARALLEL: "${toString currentPreset.numParallel}"
          OLLAMA_MAX_LOADED_MODELS: "${toString currentPreset.maxLoadedModels}"
          OLLAMA_KEEP_ALIVE: "${currentPreset.keepAlive}"
          OLLAMA_SCHED_SPREAD: "1"
          OLLAMA_KV_CACHE_TYPE: "q8_0"
          OLLAMA_MAX_QUEUE: "${toString currentPreset.maxQueue}"
          OLLAMA_MEMORY_PRESSURE_THRESHOLD: "${currentPreset.memoryPressure}"
          ${optionalString (effectiveAcceleration == "rocm") ''
          ROCR_VISIBLE_DEVICES: "0"
          ''}
          ${optionalString (effectiveAcceleration == "rocm" && cfg.advanced.rocm.gfxVersionOverride != null) ''
          HSA_OVERRIDE_GFX_VERSION: "${cfg.advanced.rocm.gfxVersionOverride}"
          ''}
        
        healthcheck:
          test: ["CMD", "curl", "-f", "http://localhost:11434/api/tags"]
          interval: 30s
          timeout: 10s
          retries: 3
          start_period: 30s
  '';

  dockerComposeFile = pkgs.writeText "docker-compose-ollama.yml" dockerComposeContent;

  # Management script
  aiStackScript = pkgs.writeShellScriptBin "ai-stack" ''
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
    
    # Verify docker group membership
    if ! groups | grep -q docker; then
      error "User must be in 'docker' group. Run: sudo usermod -aG docker $USER"
      exit 1
    fi

    # Ensure directories exist
    mkdir -p "${paths.base}" "${paths.ollama}" "${paths.compose}"
    chmod 700 "${paths.ollama}"

    COMPOSE_DIR="${paths.compose}"
    COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

    deploy_compose() {
      cp ${dockerComposeFile} "$COMPOSE_FILE"
      info "Configuration deployed (preset: ${cfg.preset})"
    }

    case "''${1:-help}" in
      start|up)
        deploy_compose
        cd "$COMPOSE_DIR"
        docker compose up -d
        success "Ollama started at http://${cfg.network.bindAddress}:11434"
        echo ""
        info "Preset: ${cfg.preset} - ${currentPreset.description}"
        info "Acceleration: ${if effectiveAcceleration != null then effectiveAcceleration else "CPU"}"
        ;;
        
      stop|down)
        cd "$COMPOSE_DIR"
        docker compose down
        success "Ollama stopped"
        ;;
        
      restart)
        deploy_compose
        cd "$COMPOSE_DIR"
        docker compose down
        docker compose up -d
        success "Ollama restarted"
        ;;
        
      status)
        echo -e "''${CYAN}=== Ollama Status ===''${NC}"
        if docker ps --format '{{.Names}}' | grep -q '^ollama$'; then
          success "Container: RUNNING"
          echo ""
          docker exec ollama ollama list 2>/dev/null || warn "Could not list models"
        else
          warn "Container: STOPPED"
        fi
        ;;
        
      logs)
        docker logs -f ollama 2>/dev/null || error "Container not running"
        ;;
        
      pull)
        shift
        if [ $# -eq 0 ]; then
          error "Usage: ai-stack pull <model>"
          echo "Examples: ai-stack pull llama3.2, ai-stack pull codellama"
          exit 1
        fi
        docker exec -it ollama ollama pull "$1"
        ;;
        
      run)
        shift
        if [ $# -eq 0 ]; then
          error "Usage: ai-stack run <model>"
          exit 1
        fi
        docker exec -it ollama ollama run "$@"
        ;;
        
      list|models)
        docker exec ollama ollama list 2>/dev/null || error "Container not running"
        ;;
        
      info)
        echo -e "''${CYAN}=== AI Stack Configuration ===''${NC}"
        echo "Preset:        ${cfg.preset}"
        echo "Description:   ${currentPreset.description}"
        echo "Acceleration:  ${if effectiveAcceleration != null then effectiveAcceleration else "CPU"}"
        echo "Bind Address:  ${cfg.network.bindAddress}:11434"
        echo "Shared Memory: ${currentPreset.shmSize}"
        echo "Parallelism:   ${toString currentPreset.numParallel}"
        echo "Max Models:    ${toString currentPreset.maxLoadedModels}"
        echo "Keep Alive:    ${currentPreset.keepAlive}"
        ${optionalString (effectiveAcceleration == "rocm" && cfg.advanced.rocm.gfxVersionOverride != null) ''
        echo "ROCm GFX:      ${cfg.advanced.rocm.gfxVersionOverride}"
        ''}
        ;;
        
      help|*)
        echo -e "''${CYAN}AI Stack - Ollama Management''${NC}"
        echo ""
        echo "Usage: ai-stack <command> [args]"
        echo ""
        echo "Commands:"
        echo "  start, up     Start Ollama container"
        echo "  stop, down    Stop Ollama container"
        echo "  restart       Restart with latest config"
        echo "  status        Show container and model status"
        echo "  logs          Follow container logs"
        echo "  pull <model>  Download a model"
        echo "  run <model>   Run interactive chat"
        echo "  list, models  List installed models"
        echo "  info          Show configuration details"
        echo ""
        echo "Examples:"
        echo "  ai-stack start"
        echo "  ai-stack pull llama3.2"
        echo "  ai-stack run codellama"
        ;;
    esac
  '';

in {
  options.services.ollamaAgentic = {
    enable = mkEnableOption "Ollama local AI stack";

    preset = mkOption {
      type = types.enum (attrNames presets);
      default = "default";
      description = "Hardware preset configuration.";
    };

    acceleration = mkOption {
      type = types.nullOr (types.enum [ "cuda" "rocm" ]);
      default = null;
      description = "GPU acceleration method (auto-detected from preset if null).";
    };

    network.bindAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
      description = "Bind address (0.0.0.0 to expose to LAN).";
    };

    advanced.rocm.gfxVersionOverride = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "HSA_OVERRIDE_GFX_VERSION for ROCm (e.g., '11.0.2' for RDNA3).";
      example = "11.0.2";
    };
  };

  config = mkIf cfg.enable {
    virtualisation.docker.enable = true;

    # User groups
    users.users.${userName}.extraGroups = [ "docker" ]
      ++ optionals (effectiveAcceleration == "rocm") [ "video" ];

    # Required packages
    environment.systemPackages = with pkgs; [
      docker
      docker-compose
      aiStackScript
      curl
    ] ++ optionals (effectiveAcceleration == "rocm") [
      rocmPackages.rocm-smi
      rocmPackages.rocminfo
    ];

    # Directory setup
    system.activationScripts.aiStackSetup = stringAfter [ "users" ] ''
      mkdir -p "${paths.base}" "${paths.ollama}" "${paths.compose}"
      chown -R ${userName}:users "${paths.base}" "${paths.ollama}"
      chmod 700 "${paths.ollama}"
    '';

    # Firewall for LAN access
    networking.firewall.allowedTCPPorts =
      mkIf (cfg.network.bindAddress != "127.0.0.1") [ 11434 ];

    # Shell aliases
    environment.shellAliases = {
      ai = "ai-stack";
      ollama-start = "ai-stack start";
      ollama-stop = "ai-stack stop";
      ollama-logs = "ai-stack logs";
    };
  };
}

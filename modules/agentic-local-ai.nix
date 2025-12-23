# /etc/nixos/agentic-local-ai.nix

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

  presetConfigs = {
    cpu-fallback = { shmSize = "8gb"; numParallel = 1; maxLoadedModels = 2; keepAlive = "12h"; maxQueue = 128; memoryPressure = "0.90"; };
    default      = { shmSize = "16gb"; numParallel = 4; maxLoadedModels = 4; keepAlive = "24h"; maxQueue = 512; memoryPressure = "0.85"; };
    high-vram    = { shmSize = "32gb"; numParallel = 8; maxLoadedModels = 6; keepAlive = "48h"; maxQueue = 1024; memoryPressure = "0.80"; };
    rocm-multi   = { shmSize = "48gb"; numParallel = 12; maxLoadedModels = 8; keepAlive = "72h"; maxQueue = 2048; memoryPressure = "0.75"; };
    cuda         = { shmSize = "48gb"; numParallel = 12; maxLoadedModels = 8; keepAlive = "72h"; maxQueue = 2048; memoryPressure = "0.75"; };
    pewdiepie    = { shmSize = "64gb"; numParallel = 16; maxLoadedModels = 10; keepAlive = "72h"; maxQueue = 2048; memoryPressure = "0.75"; };
  };

  currentPreset = presetConfigs.${cfg.preset};

  effectiveAcceleration =
    if cfg.acceleration != null then cfg.acceleration
    else if cfg.preset == "rocm-multi" then "rocm"
    else if cfg.preset == "cuda" then "cuda"
    else null;

  ollamaImage =
    if effectiveAcceleration == "rocm" then "ollama/ollama:rocm"
    else "ollama/ollama";

  gfxVersionOverride = 
    if effectiveAcceleration == "rocm" && cfg.advanced.rocm.gfxVersionOverride != null
    then "      HSA_OVERRIDE_GFX_VERSION: \"${cfg.advanced.rocm.gfxVersionOverride}\"\n"
    else "";

  rocmEnvVars =
    if effectiveAcceleration == "rocm"
    then "      ROCR_VISIBLE_DEVICES: \"0\"\n${gfxVersionOverride}"
    else "";

  dockerComposeYml = pkgs.writeText "docker-compose-agentic-ai.yml" (
  "services:\n  ollama:\n    image: ${ollamaImage}\n    container_name: ollama\n    restart: unless-stopped\n    ipc: host\n    shm_size: \"${currentPreset.shmSize}\"\n    security_opt:\n      - no-new-privileges:true\n"
  + (if effectiveAcceleration == "rocm" then
      "    devices:\n      - \"/dev/kfd:/dev/kfd\"\n      - \"/dev/dri:/dev/dri\"\n    group_add:\n      - video\n"
    else if effectiveAcceleration == "cuda" then
      "    deploy:\n      resources:\n        reservations:\n          devices:\n            - driver: nvidia\n              count: all\n              capabilities: [gpu]\n        limits:\n          memory: ${currentPreset.shmSize}\n"
    else "")
  + (if effectiveAcceleration == "rocm" then
      "    deploy:\n      resources:\n        limits:\n          memory: ${currentPreset.shmSize}\n"
    else "")
  + "    volumes:\n      - ${paths.ollama}:/root/.ollama\n    ports:\n      - \"${cfg.network.ollamaBindAddress}:11434:11434\"\n    environment:\n      OLLAMA_FLASH_ATTENTION: \"1\"\n      OLLAMA_NUM_PARALLEL: \"${toString currentPreset.numParallel}\"\n      OLLAMA_MAX_LOADED_MODELS: \"${toString currentPreset.maxLoadedModels}\"\n      OLLAMA_KEEP_ALIVE: \"${currentPreset.keepAlive}\"\n      OLLAMA_SCHED_SPREAD: \"1\"\n      OLLAMA_KV_CACHE_TYPE: \"q8_0\"\n      OLLAMA_MAX_QUEUE: \"${toString currentPreset.maxQueue}\"\n      OLLAMA_MEMORY_PRESSURE_THRESHOLD: \"${currentPreset.memoryPressure}\"\n"
  + rocmEnvVars
  );

  aiStackScript = pkgs.writeShellScriptBin "ai-stack" ''
    #!/usr/bin/env bash
    set -euo pipefail

    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m'

    error() { echo -e "''${RED}[ERROR]''${NC} $*" >&2; }
    success() { echo -e "''${GREEN}[SUCCESS]''${NC} $*"; }
    warn() { echo -e "''${YELLOW}[WARN]''${NC} $*"; }
    info() { echo -e "''${BLUE}[INFO]''${NC} $*"; }

    if ! groups | grep -q docker; then
      error "User must be in 'docker' group."
      exit 1
    fi

    mkdir -p "${paths.base}" "${paths.ollama}" "${paths.state}"
    chmod 700 "${paths.ollama}" "${paths.state}"

    COMPOSE_DIR="${paths.base}"
    COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

    cd "$COMPOSE_DIR"

    deploy_compose() {
      if [ ! -f "$COMPOSE_FILE" ] || [ "${dockerComposeYml}" -nt "$COMPOSE_FILE" ]; then
        cp ${dockerComposeYml} "$COMPOSE_FILE"
      fi
    }

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
        ;;
    esac
  '';

in
{
  options.services.ollamaAgentic = {
    enable = mkEnableOption "Ollama local AI stack (no WebUI)";

    preset = mkOption {
      type = types.enum [ "cpu-fallback" "default" "high-vram" "rocm-multi" "cuda" "pewdiepie" ];
      default = "default";
    };

    acceleration = mkOption {
      type = types.nullOr (types.enum [ "cuda" "rocm" ]);
      default = null;
    };

    network.ollamaBindAddress = mkOption {
      type = types.str;
      default = "127.0.0.1";
    };

    advanced.rocm.gfxVersionOverride = mkOption {
      type = types.nullOr types.str;
      default = null;
    };
  };

  config = mkIf cfg.enable {
    virtualisation.docker.enable = true;

    users.users.${userName}.extraGroups = [ "docker" ] ++ optionals (effectiveAcceleration == "rocm") [ "video" ];

    environment.systemPackages = with pkgs; [
      docker docker-compose aiStackScript
    ] ++ optionals (effectiveAcceleration == "rocm") [
      rocmPackages.rocm-smi rocmPackages.rocminfo
    ];

    system.activationScripts.aiAgentSetup = stringAfter [ "users" ] ''
      mkdir -p "${paths.base}" "${paths.ollama}" "${paths.state}"
      chown -R ${userName}:users "${paths.base}" "${paths.ollama}" "${paths.state}"
      chmod 700 "${paths.ollama}" "${paths.state}"
    '';

    networking.firewall.allowedTCPPorts = mkIf (cfg.network.ollamaBindAddress != "127.0.0.1") [ 11434 ];

    environment.shellAliases = {
      ai = "ai-stack";
      ollama-logs = "ai-stack logs";
    };
  };
}

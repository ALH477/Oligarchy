# /etc/nixos/agentic-local-ai.nix

{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.ollamaAgentic;

  userName = "asher";
  userHome = config.users.users.${userName}.home or "/home/${userName}";
  
  paths = {
    base = "${userHome}/.config/ollama-agentic/ai-stack";
    ollama = "${userHome}/.ollama";
    foldingAtHome = "${userHome}/foldingathome-data";
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
    else if effectiveAcceleration == "cuda" then "ollama/ollama:cuda"
    else "ollama/ollama";

  gfxVersionOverride = 
    if effectiveAcceleration == "rocm" && cfg.advanced.rocm.gfxVersionOverride != null
    then "      HSA_OVERRIDE_GFX_VERSION: \"${cfg.advanced.rocm.gfxVersionOverride}\"\n"
    else "";

  rocmEnvVars =
    if effectiveAcceleration == "rocm"
    then "      ROCR_VISIBLE_DEVICES: \"0\"\n${gfxVersionOverride}"
    else "";

  cudaEnvVars =
    if effectiveAcceleration == "cuda"
    then "      NVIDIA_VISIBLE_DEVICES: all\n      NVIDIA_DRIVER_CAPABILITIES: compute,utility\n"
    else "";

  ollamaBind = if cfg.network.exposeToLAN then "0.0.0.0" else "127.0.0.1";

  dockerComposeYml = pkgs.writeText "docker-compose-agentic-ai.yml" (
  "services:\n  ollama:\n    image: ${ollamaImage}\n    container_name: ollama\n    restart: unless-stopped\n    ipc: host\n    shm_size: \"${currentPreset.shmSize}\"\n    security_opt:\n      - no-new-privileges:true\n"
  + (if effectiveAcceleration == "rocm" then
      "    devices:\n      - \"/dev/kfd:/dev/kfd\"\n      - \"/dev/dri:/dev/dri\"\n    group_add:\n      - video\n"
    else if effectiveAcceleration == "cuda" then
      "    deploy:\n      resources:\n        reservations:\n          devices:\n            - driver: nvidia\n              count: all\n              capabilities: [gpu]\n"
    else "")
  + (if effectiveAcceleration == "rocm" || effectiveAcceleration == "cuda" then
      "    deploy:\n      resources:\n        limits:\n          memory: ${currentPreset.shmSize}\n"
    else "")
  + "    volumes:\n      - ${paths.ollama}:/root/.ollama\n    ports:\n      - \"${ollamaBind}:11434:11434\"\n    environment:\n      OLLAMA_FLASH_ATTENTION: \"1\"\n      OLLAMA_NUM_PARALLEL: \"${toString currentPreset.numParallel}\"\n      OLLAMA_MAX_LOADED_MODELS: \"${toString currentPreset.maxLoadedModels}\"\n      OLLAMA_KEEP_ALIVE: \"${currentPreset.keepAlive}\"\n      OLLAMA_SCHED_SPREAD: \"1\"\n      OLLAMA_KV_CACHE_TYPE: \"q8_0\"\n      OLLAMA_MAX_QUEUE: \"${toString currentPreset.maxQueue}\"\n      OLLAMA_MEMORY_PRESSURE_THRESHOLD: \"${currentPreset.memoryPressure}\"\n"
  + rocmEnvVars
  + cudaEnvVars
  + (if cfg.advanced.foldingAtHome.enable then
      "\n  foldingathome:\n    image: ghcr.io/linuxserver/foldingathome:latest\n    container_name: foldingathome\n    restart: unless-stopped\n    security_opt:\n      - no-new-privileges:true\n    cap_drop:\n      - ALL\n    environment:\n      USER: ${cfg.advanced.foldingAtHome.user}\n      TEAM: \"${toString cfg.advanced.foldingAtHome.team}\"\n      ENABLE_GPU: \"true\"\n      ENABLE_SMP: \"true\"\n    volumes:\n      - ${paths.foldingAtHome}:/config\n"
      + (if effectiveAcceleration == "rocm" then
          "    devices:\n      - \"/dev/kfd:/dev/kfd\"\n      - \"/dev/dri:/dev/dri\"\n    group_add:\n      - video\n"
        else if effectiveAcceleration == "cuda" then
          "    deploy:\n      resources:\n        reservations:\n          devices:\n            - driver: nvidia\n              count: all\n              capabilities: [gpu]\n"
        else "")
      + "\n"
    else "")
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

    mkdir -p "${paths.base}" "${paths.ollama}" ${optionalString cfg.advanced.foldingAtHome.enable "\"${paths.foldingAtHome}\""} "${paths.state}"
    chmod 700 "${paths.ollama}" "${paths.state}"

    COMPOSE_DIR="${paths.base}"
    COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

    cd "$COMPOSE_DIR"

    deploy_compose() {
      if [ ! -f "$COMPOSE_FILE" ] || [ "${dockerComposeYml}" -nt "$COMPOSE_FILE" ]; then
        info "Deploying updated compose file..."
        cp ${dockerComposeYml} "$COMPOSE_FILE"
      fi
    }

    is_running() {
      docker compose ps "$1" 2>/dev/null | grep -q "Up"
    }

    wait_for_api() {
      info "Waiting for Ollama API to be ready (up to 60 seconds)..."
      local count=0
      while [ $count -lt 60 ]; do
        if curl -s http://localhost:11434/api/tags >/dev/null 2>&1; then
          success "Ollama API is ready!"
          return 0
        fi
        sleep 1
        count=$((count + 1))
      done
      warn "Ollama API did not become ready in 60 seconds"
      return 1
    }

    case "''${1:-}" in
      start|up)
        deploy_compose
        if is_running ollama; then
          success "Ollama is already running"
        else
          info "Starting Ollama..."
          docker compose up -d
          wait_for_api
        fi
        echo ""
        success "Ollama running on port 11434"
${if cfg.network.exposeToLAN then ''
        success "→ Exposed to LAN (accessible from other devices on your network)"
'' else ''
        info "→ Bound to localhost only (secure default)"
        info "   To expose to LAN, set services.ollamaAgentic.network.exposeToLAN = true;"
''}
${if cfg.advanced.foldingAtHome.enable then ''
        if is_running foldingathome; then
          success "Folding@Home is running (contributing when idle)"
        else
          info "Starting Folding@Home..."
          docker compose up -d foldingathome
          success "Folding@Home started"
        fi
'' else ""}
        echo "User-friendly interfaces installed:"
        echo "  • aichat     - Advanced CLI REPL (run 'aichat')"
        echo "  • oterm      - Beautiful TUI (run 'oterm')"
        echo "  • alpaca     - Native GTK desktop app (run 'alpaca' or find in menu)"
        echo "  • dalai serve - Simple web UI (run 'dalai serve' then open http://localhost:3000)"
        ;;

      stop|down)
        if is_running ollama; then
          info "Stopping Ollama..."
          docker compose down ollama
        fi
${if cfg.advanced.foldingAtHome.enable then ''
        if is_running foldingathome; then
          info "Stopping Folding@Home..."
          docker compose down foldingathome
        fi
'' else ""}
        success "Services stopped"
        ;;

      restart)
        info "Restarting services..."
        docker compose down || true
        deploy_compose
        docker compose up -d
        wait_for_api
        success "Services restarted"
        ;;

      status)
        echo "=== Service Status ==="
        docker compose ps
        echo ""
        if is_running ollama; then
          info "Ollama container is Up"
          if curl -s http://localhost:11434/api/tags >/dev/null 2>&1; then
            success "Ollama API is responsive"
          else
            warn "Ollama API not yet responsive"
          fi
        else
          warn "Ollama container is not running"
        fi
${if cfg.advanced.foldingAtHome.enable then ''
        if is_running foldingathome; then
          success "Folding@Home is running"
        else
          warn "Folding@Home is not running"
        fi
'' else ""}
        echo ""
        info "=== Resource Usage ==="
        docker stats --no-stream 2>/dev/null || echo "No containers running"
        ;;

      pull)
        if [ -z "''${2:-}" ]; then
          error "Usage: ai-stack pull <model>"
          exit 1
        fi
        if ! is_running ollama; then
          error "Ollama container is not running. Start it with 'ai-stack start' first."
          exit 1
        fi
        info "Pulling model: $2"
        docker exec ollama ollama pull "$2"
        success "Model $2 pulled successfully"
        ;;

      logs)
        docker compose logs -f "''${2:-ollama}"
        ;;

      *)
        cat <<EOF
ai-stack - Ollama Management

Usage: ai-stack <command> [args]

Commands:
  start     Start Ollama (and Folding@Home if enabled)
  stop      Stop services
  restart   Restart services
  status    Show detailed status
  pull <model>  Pull a model
  logs [service]  Follow logs (default: ollama)

Optional Folding@Home:
  ${if cfg.advanced.foldingAtHome.enable then "Enabled (user: ${cfg.advanced.foldingAtHome.user}, team: ${toString cfg.advanced.foldingAtHome.team})" else "Disabled"}

Network:
  Current: ${if cfg.network.exposeToLAN then "Exposed to LAN" else "Localhost only"}
  To expose to LAN: services.ollamaAgentic.network.exposeToLAN = true;

User-friendly interfaces:
  aichat     - Powerful CLI with sessions, RAG, agents
  oterm      - Terminal UI with persistent chats
  alpaca     - Native GTK desktop client (run 'alpaca' or find in menu)
  dalai serve - Browser-based chat UI

Ollama API: http://<your-ip>:11434 (if LAN exposed) or http://127.0.0.1:11434
EOF
        exit 1
        ;;
    esac
  '';

in
{
  options.services.ollamaAgentic = {
    enable = mkEnableOption "Ollama local AI stack with user-friendly interfaces";

    preset = mkOption {
      type = types.enum [ "cpu-fallback" "default" "high-vram" "rocm-multi" "cuda" "pewdiepie" ];
      default = "default";
    };

    acceleration = mkOption {
      type = types.nullOr (types.enum [ "cuda" "rocm" ]);
      default = null;
      description = "Force CUDA or ROCm. Null = standard image (Vulkan if available).";
    };

    network = {
      exposeToLAN = mkOption {
        type = types.bool;
        default = false;
        description = mdDoc ''
          If true, bind Ollama to 0.0.0.0:11434 (accessible from other devices on your LAN).
          Default false (localhost only) for security.
        '';
      };
    };

    advanced = {
      rocm.gfxVersionOverride = mkOption {
        type = types.nullOr types.str;
        default = null;
      };

      foldingAtHome = {
        enable = mkEnableOption "Folding@Home container (contribute to science when idle)";

        user = mkOption {
          type = types.str;
          default = "Anonymous";
          description = "Folding@Home username";
        };

        team = mkOption {
          type = types.int;
          default = 0;
          description = "Folding@Home team number";
        };
      };
    };
  };

  config = mkIf cfg.enable {
    virtualisation.docker.enable = true;

    users.users.${userName}.extraGroups = [ "docker" ] ++ optionals (effectiveAcceleration == "rocm") [ "video" ];

    environment.systemPackages = with pkgs; [
      docker docker-compose aiStackScript
      aichat        # Advanced CLI
      oterm         # TUI
      alpaca        # GTK desktop client
      dalai         # Simple web UI
    ] ++ optionals (effectiveAcceleration == "rocm") [
      rocmPackages.rocm-smi rocmPackages.rocminfo
    ];

    system.activationScripts.aiAgentSetup = stringAfter [ "users" ] ''
      mkdir -p "${paths.base}" "${paths.ollama}" ${optionalString cfg.advanced.foldingAtHome.enable "\"${paths.foldingAtHome}\""} "${paths.state}"
      chown -R ${userName}:users "${paths.base}" "${paths.ollama}" ${optionalString cfg.advanced.foldingAtHome.enable "\"${paths.foldingAtHome}\""} "${paths.state}"
      chmod 700 "${paths.ollama}" "${paths.state}"
    '';

    networking.firewall.allowedTCPPorts = mkIf cfg.network.exposeToLAN [ 11434 ];

    environment.shellAliases = {
      ai = "ai-stack";
      ollama-logs = "ai-stack logs";
    };
  };
}

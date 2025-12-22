# /etc/nixos/agentic-local-ai.nix

{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.ollamaAgentic;

  userName = "asher";
  userHome = config.users.users.${userName}.home or "/home/${userName}";

  presetConfigs = {
    cpu-fallback = {
      description = "CPU-only fallback.";
      numParallel = 1;
      maxLoadedModels = 2;
      keepAlive = "12h";
      shmSize = "8gb";
      recommendedModels = [ "tinyllama:1.1b-chat-q8_0" "phi3:3.8b-mini-128k-instruct-q8_0" "gemma2:2b-instruct-q8_0" "qwen2.5:3b-instruct-q8_0" ];
    };

    default = {
      description = "Balanced for consumer AMD GPUs including Radeon 780M iGPU.";
      numParallel = 4;
      maxLoadedModels = 4;
      keepAlive = "24h";
      shmSize = "16gb";
      recommendedModels = [ "llama3.2:3b-instruct-q8_0" "phi3:14b-medium-128k-instruct-q6_K" "qwen2.5-coder:14b-q6_K" "gemma2:27b-instruct-q6_K" ];
    };

    high-vram = {
      description = "For high-end discrete GPUs.";
      numParallel = 8;
      maxLoadedModels = 6;
      keepAlive = "48h";
      shmSize = "32gb";
      recommendedModels = [ "llama3.1:70b-instruct-q6_K" "qwen2.5:72b-instruct-q5_K_M" ];
    };

    rocm-multi = {
      description = "Multi-GPU ROCm tier: uses both iGPU (780M) and dGPU (7700S) for maximum performance.";
      numParallel = 12;
      maxLoadedModels = 8;
      keepAlive = "72h";
      shmSize = "48gb";
      recommendedModels = [ "llama3.1:70b-instruct-q6_K" "qwen2.5:72b-instruct-q5_K_M" "deepseek-coder-v2:236b-lite-instruct-q4_K_M" "gemma2:27b-instruct-q8_0" ];
    };

    cuda = {
      description = "Optimized for NVIDIA CUDA GPUs (8–48GB VRAM). Supports larger models and higher parallelism.";
      numParallel = 12;
      maxLoadedModels = 8;
      keepAlive = "72h";
      shmSize = "48gb";
      acceleration = "cuda";
      recommendedModels = [ "llama3.1:70b-instruct-q6_K" "qwen2.5:72b-instruct-q5_K_M" "mixtral:8x22b-instruct-q4_K_M" "gemma2:27b-instruct-q8_0" ];
    };

    pewdiepie = {
      description = "Extreme tier (multi-GPU NVIDIA CUDA only).";
      numParallel = 16;
      maxLoadedModels = 10;
      keepAlive = "72h";
      shmSize = "64gb";
      acceleration = "cuda";
      recommendedModels = [ "llama3.1:405b-instruct-q4_K_M" ];
    };
  };

  currentPreset = presetConfigs.${cfg.preset};

  effectiveAcceleration = if cfg.acceleration != null then cfg.acceleration else currentPreset.acceleration or null;

  ollamaImage = if effectiveAcceleration == "rocm" then "ollama/ollama:rocm"
                else if effectiveAcceleration == "cuda" then "ollama/ollama:cuda"
                else "ollama/ollama:latest";

  dockerComposeYml = pkgs.writeText "docker-compose-agentic-ai.yml" (
    ''
      version: "3.9"
      services:
        ollama:
          image: ${ollamaImage}
          container_name: ollama
          restart: unless-stopped
          ipc: host
          shm_size: "${currentPreset.shmSize}"
          environment:
            OLLAMA_FLASH_ATTENTION: "1"
            OLLAMA_NUM_PARALLEL: "${toString currentPreset.numParallel}"
            OLLAMA_MAX_LOADED_MODELS: "${toString currentPreset.maxLoadedModels}"
            OLLAMA_KEEP_ALIVE: "${currentPreset.keepAlive}"
            OLLAMA_SCHED_SPREAD: "1"
            OLLAMA_KV_CACHE_TYPE: "q8_0"
    ''
    + optionalString (effectiveAcceleration == "rocm") ''
            ROCR_VISIBLE_DEVICES: "0,1"
            HSA_OVERRIDE_GFX_VERSION: "11.0.0"
    ''
    + optionalString (effectiveAcceleration == "rocm") ''
          devices:
            - /dev/kfd:/dev/kfd
            - /dev/dri:/dev/dri
    ''
    + optionalString (effectiveAcceleration == "cuda") ''
          deploy:
            resources:
              reservations:
                devices:
                  - driver: nvidia
                    count: all
                    capabilities: [gpu]
    ''
    + ''
          volumes:
            - ${userHome}/.ollama:/root/.ollama
          ports:
            - "127.0.0.1:11434:11434"
          healthcheck:
            test: ["CMD", "wget", "-qO-", "http://localhost:11434/api/tags"]
            interval: 30s
            timeout: 10s
            retries: 3

        open-webui:
          image: ghcr.io/open-webui/open-webui:main
          container_name: open-webui
          restart: unless-stopped
          read_only: true
          tmpfs:
            - /tmp
          volumes:
            - ${userHome}/open-webui-data:/app/backend/data
          ports:
            - "127.0.0.1:8080:8080"
          environment:
            OLLAMA_BASE_URL: http://ollama:11434
            ENABLE_SIGNUP: "false"
            WEBUI_AUTH: "true"
            DEFAULT_USER_ROLE: admin
          depends_on:
            ollama:
              condition: service_healthy
          healthcheck:
            test: ["CMD", "wget", "-qO-", "http://localhost:8080"]
            interval: 30s
            timeout: 10s
            retries: 3
    ''
    + optionalString cfg.advanced.foldingAtHome.enable (
      ''

        foldingathome:
          image: ghcr.io/linuxserver/foldingathome:latest
          container_name: foldingathome
          restart: unless-stopped
          environment:
            USER: Anonymous
            TEAM: "0"
            ENABLE_GPU: "true"
            ENABLE_SMP: "true"
          volumes:
            - ${userHome}/foldingathome-data:/config
      ''
      + optionalString (effectiveAcceleration == "rocm") ''
          devices:
            - /dev/kfd:/dev/kfd
            - /dev/dri:/dev/dri
      ''
      + optionalString (effectiveAcceleration == "cuda") ''
          deploy:
            resources:
              reservations:
                devices:
                  - driver: nvidia
                    count: all
                    capabilities: [gpu]
      ''
    )
  );

  recommendedModelsArray = builtins.concatStringsSep "\n        " currentPreset.recommendedModels;

  aiStackScript = pkgs.writeShellScriptBin "ai-stack" ''
    #!/usr/bin/env bash
    set -euo pipefail

    USER_HOME="${userHome}"
    PRESET="${cfg.preset}"
    PRESET_DESC="${currentPreset.description}"

    if ! groups | grep -q docker; then
      echo "Error: User must be in 'docker' group."
      exit 1
    fi

    COMPOSE_DIR="$USER_HOME/.config/ollama-agentic/ai-stack"
    mkdir -p "$COMPOSE_DIR" "$USER_HOME/.ollama" "$USER_HOME/open-webui-data"
    ${optionalString cfg.advanced.foldingAtHome.enable ''mkdir -p "$USER_HOME/foldingathome-data"''}
    chmod 700 "$USER_HOME/.ollama" "$USER_HOME/open-webui-data"

    COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

    if [ ! -f "$COMPOSE_FILE" ]; then
      echo "Deploying Agentic Local AI stack ($PRESET preset)..."
      echo "$PRESET_DESC"
      ${optionalString cfg.advanced.foldingAtHome.enable "echo 'Folding@Home container enabled'"}
      cp ${dockerComposeYml} "$COMPOSE_FILE"
    fi

    if command -v rocminfo >/dev/null 2>&1 && [[ "$PRESET" != "cuda" ]]; then
      echo "ROCm multi-GPU mode: Both RX 7700S (dGPU) and Radeon 780M (iGPU) visible to Ollama"
    fi

    cd "$COMPOSE_DIR"

    case "''${1:-start}" in
      start|up)
        docker compose pull
        docker compose up -d
        echo "Agentic Local AI ($PRESET) active → http://localhost:8080"
        ${optionalString cfg.advanced.foldingAtHome.enable "echo 'Folding@Home running in background'"}
        echo "Recommended models:"
        echo "${recommendedModelsArray}"
        ;;
      stop|down)
        docker compose down
        ;;
      logs)
        docker compose logs -f "''${@:2}"
        ;;
      pull)
        if [ -z "''${2:-}" ]; then
          echo "Usage: ai-stack pull <model>"
          exit 1
        fi
        docker exec -it ollama ollama pull "$2"
        ;;
      tune)
        if [[ "$PRESET" == "cuda" ]]; then
          nvidia-smi || echo "nvidia-smi not available"
        else
          rocm-smi --showmeminfo vram 2>/dev/null || echo "ROCm not active"
        fi
        ;;
      backup)
        TIMESTAMP=$(date +%Y%m%d_%H%M)
        tar -czf "$USER_HOME/ai-backup-''${TIMESTAMP}.tar.gz" "$USER_HOME/.ollama" "$USER_HOME/open-webui-data" ${optionalString cfg.advanced.foldingAtHome.enable "\"$USER_HOME/foldingathome-data\""}
        echo "Backup written to $USER_HOME/ai-backup-''${TIMESTAMP}.tar.gz"
        ;;
      *)
        echo "Usage: ai-stack [start|stop|logs|pull <model>|tune|backup]"
        ;;
    esac
  '';
in
{
  options.services.ollamaAgentic = {
    enable = mkEnableOption "Tiered local AI stack (Ollama + Open WebUI)";

    preset = mkOption {
      type = types.enum [ "cpu-fallback" "default" "high-vram" "rocm-multi" "cuda" "pewdiepie" ];
      default = "default";
      description = "Performance tier preset. Use 'rocm-multi' for both iGPU + dGPU acceleration.";
    };

    acceleration = mkOption {
      type = types.nullOr (types.enum [ "cuda" "rocm" ]);
      default = null;
      description = "Force acceleration backend (overrides preset).";
    };

    advanced.foldingAtHome.enable = mkEnableOption "Folding@Home container";
  };

  config = mkIf cfg.enable {
    assertions = [
      { assertion = cfg.preset != "pewdiepie" || effectiveAcceleration == "cuda"; message = "pewdiepie requires CUDA."; }
      { assertion = cfg.preset != "cuda" || effectiveAcceleration == "cuda"; message = "cuda preset requires NVIDIA GPU and CUDA support."; }
      { assertion = cfg.preset != "rocm-multi" || effectiveAcceleration == "rocm"; message = "rocm-multi requires ROCm."; }
    ];

    virtualisation.docker.enable = true;

    users.users.${userName}.extraGroups = [ "docker" "video" "render" ] ++ optional (effectiveAcceleration == "cuda") "nvidia";

    environment.systemPackages = with pkgs; [ docker rocmPackages.rocm-smi rocmPackages.rocminfo aiStackScript ];

    system.activationScripts.aiAgentSetup = ''
      mkdir -p ${userHome}/.ollama ${userHome}/open-webui-data ${userHome}/.config/ollama-agentic/ai-stack ${optionalString cfg.advanced.foldingAtHome.enable "${userHome}/foldingathome-data"}
      chown -R ${userName}:users ${userHome}/.ollama ${userHome}/open-webui-data ${userHome}/.config/ollama-agentic ${optionalString cfg.advanced.foldingAtHome.enable "${userHome}/foldingathome-data"}
      chmod 700 ${userHome}/.ollama ${userHome}/open-webui-data
    '';
  };
}

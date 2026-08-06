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
  # contextLength -> OLLAMA_CONTEXT_LENGTH (default is 2048; flash-attention's
  # benefit only kicks in above ~8k, so anything below "default" leaves it
  # unused). gpuOverheadBytes -> OLLAMA_GPU_OVERHEAD, only applied when a GPU
  # acceleration is active — reserves VRAM headroom so a near-full GPU doesn't
  # OOM and fall back to (far slower) CPU inference mid-session.
  presets = {
    cpu-fallback = {
      shmSize = "8gb";
      numParallel = 1;
      maxLoadedModels = 2;
      keepAlive = "12h";
      maxQueue = 128;
      contextLength = 4096;
      gpuOverheadBytes = null;
      description = "CPU-only fallback mode";
    };

    default = {
      shmSize = "16gb";
      numParallel = 4;
      maxLoadedModels = 4;
      keepAlive = "24h";
      maxQueue = 512;
      contextLength = 8192;
      gpuOverheadBytes = null;
      description = "Default GPU configuration";
    };

    high-vram = {
      shmSize = "32gb";
      numParallel = 8;
      maxLoadedModels = 6;
      keepAlive = "48h";
      maxQueue = 1024;
      contextLength = 16384;
      gpuOverheadBytes = 1073741824; # 1 GiB
      description = "High VRAM GPU (16GB+)";
    };

    rocm-multi = {
      shmSize = "48gb";
      numParallel = 12;
      maxLoadedModels = 8;
      keepAlive = "72h";
      maxQueue = 2048;
      contextLength = 32768;
      gpuOverheadBytes = 2147483648; # 2 GiB
      description = "AMD ROCm multi-GPU";
    };

    cuda = {
      shmSize = "48gb";
      numParallel = 12;
      maxLoadedModels = 8;
      keepAlive = "72h";
      maxQueue = 2048;
      contextLength = 32768;
      gpuOverheadBytes = 2147483648; # 2 GiB
      description = "NVIDIA CUDA configuration";
    };

    pewdiepie = {
      shmSize = "64gb";
      numParallel = 16;
      maxLoadedModels = 10;
      keepAlive = "72h";
      maxQueue = 2048;
      contextLength = 32768;
      gpuOverheadBytes = 2147483648; # 2 GiB
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
    if effectiveAcceleration == "rocm" then "ollama/ollama:0.15.5-rc2-rocm"
    else "ollama/ollama:latest";

  # Generate docker-compose.yml
  dockerComposeContent = lib.generators.toYAML { } {
    version = "3.9";

    services.ollama = {
      image = ollamaImage;
      container_name = "ollama";
      restart = "unless-stopped";
      ipc = "host";
      shm_size = currentPreset.shmSize;
      security_opt = [ "no-new-privileges:true" ];
    } // lib.optionalAttrs (cfg.containerMemoryLimitGB != null) {
      # cgroup v2 memory.max / memory.swap.max. No mem_swappiness — that
      # docker flag needs cgroup v1 and errors under this host's cgroup v2.
      mem_limit = "${toString cfg.containerMemoryLimitGB}g";
      memswap_limit = "${toString (cfg.containerMemoryLimitGB + (if cfg.dedicatedSwap.enable then cfg.dedicatedSwap.sizeGB else 0))}g";
    } // {

      devices = lib.optionals (effectiveAcceleration == "rocm") [
        "/dev/kfd:/dev/kfd"
        "/dev/dri:/dev/dri"
      ];

      group_add = lib.optionals (effectiveAcceleration == "rocm") [ "video" ];

      deploy = lib.optionalAttrs (effectiveAcceleration == "cuda") {
        resources.reservations.devices = [{
          driver = "nvidia";
          count = "all";
          capabilities = [ "gpu" ];
        }];
      };

      volumes = [ "${paths.ollama}:/root/.ollama" ];

      ports = [ "${cfg.network.bindAddress}:11434:11434" ];

      environment = {
        OLLAMA_FLASH_ATTENTION = "1";
        OLLAMA_NUM_PARALLEL = toString currentPreset.numParallel;
        OLLAMA_MAX_LOADED_MODELS = toString currentPreset.maxLoadedModels;
        OLLAMA_KEEP_ALIVE = currentPreset.keepAlive;
        OLLAMA_SCHED_SPREAD = "1";
        OLLAMA_KV_CACHE_TYPE = "q8_0";
        OLLAMA_MAX_QUEUE = toString currentPreset.maxQueue;
        OLLAMA_CONTEXT_LENGTH = toString currentPreset.contextLength;
      } // lib.optionalAttrs (effectiveAcceleration == "rocm") {
        ROCR_VISIBLE_DEVICES = "1, 0";
      } // lib.optionalAttrs (effectiveAcceleration == "rocm" && cfg.advanced.rocm.gfxVersionOverride != null) {
        HSA_OVERRIDE_GFX_VERSION = cfg.advanced.rocm.gfxVersionOverride;
      } // lib.optionalAttrs (effectiveAcceleration != null && currentPreset.gpuOverheadBytes != null) {
        OLLAMA_GPU_OVERHEAD = toString currentPreset.gpuOverheadBytes;
      };

      healthcheck = {
        test = [ "CMD" "curl" "-f" "http://localhost:11434/api/tags" ];
        interval = "30s";
        timeout = "10s";
        retries = 3;
        start_period = "30s";
      };
    };
  };

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
        echo "Preset:         ${cfg.preset}"
        echo "Description:    ${currentPreset.description}"
        echo "Acceleration:   ${if effectiveAcceleration != null then effectiveAcceleration else "CPU"}"
        echo "Bind Address:   ${cfg.network.bindAddress}:11434"
        echo "Shared Memory:  ${currentPreset.shmSize}"
        echo "Parallelism:    ${toString currentPreset.numParallel}"
        echo "Max Models:     ${toString currentPreset.maxLoadedModels}"
        echo "Keep Alive:     ${currentPreset.keepAlive}"
        echo "Context Length:  ${toString currentPreset.contextLength}"
        ${optionalString (effectiveAcceleration != null && currentPreset.gpuOverheadBytes != null) ''
        echo "GPU Overhead:   $(( ${toString currentPreset.gpuOverheadBytes} / 1073741824 )) GiB"
        ''}
        ${optionalString (effectiveAcceleration == "rocm" && cfg.advanced.rocm.gfxVersionOverride != null) ''
        echo "ROCm GFX:       ${cfg.advanced.rocm.gfxVersionOverride}"
        ''}
        ${optionalString cfg.dedicatedSwap.enable ''
        echo "Dedicated Swap: ${cfg.dedicatedSwap.path} (${toString cfg.dedicatedSwap.sizeGB} GiB, priority ${toString cfg.dedicatedSwap.priority})"
        ''}
        ${optionalString (cfg.containerMemoryLimitGB != null) ''
        echo "Container Mem:  ${toString cfg.containerMemoryLimitGB} GiB RAM + ${toString (cfg.containerMemoryLimitGB + (if cfg.dedicatedSwap.enable then cfg.dedicatedSwap.sizeGB else 0))} GiB swap cap"
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

in
{
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
      description = ''
        Bind address for the Ollama API. Default is loopback-only: the API is
        unauthenticated, so exposing it ("0.0.0.0") hands LAN/tailnet peers
        free inference and model management. Set network.openFirewall too if
        you really want LAN access.
      '';
    };

    network.openFirewall = mkOption {
      type = types.bool;
      default = false;
      description = "Open port 11434 in the firewall (only meaningful when bindAddress is not 127.0.0.1).";
    };

    advanced.rocm.gfxVersionOverride = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "HSA_OVERRIDE_GFX_VERSION for ROCm (e.g., '11.0.2' for RDNA3).";
      example = "11.0.2";
    };

    dedicatedSwap = {
      enable = mkEnableOption "a swapfile dedicated to AI-stack overflow, separate from the system's generic backup swap";

      path = mkOption {
        type = types.path;
        default = "/var/lib/ollama-agentic/swapfile";
        description = "Location of the dedicated swapfile. Lives on the root filesystem so it's always available (unlike ad hoc data-drive mounts).";
      };

      sizeGB = mkOption {
        type = types.int;
        default = 24;
        description = "Size of the dedicated swapfile in GiB.";
      };

      priority = mkOption {
        type = types.int;
        default = 50;
        description = ''
          swapDevices priority. Should sit between zram (typically 100) and
          the system's generic backup swap (typically 10) — AI overflow
          drains here first, before falling through to the shared backup
          tier used by everything else on the box.
        '';
      };
    };

    containerMemoryLimitGB = mkOption {
      type = types.nullOr types.int;
      default = null;
      description = ''
        Caps the ollama container via docker `mem_limit`/`memswap_limit`
        (cgroup v2 memory.max / memory.swap.max). Null (default) leaves the
        container unlimited, as before. When set, memswap_limit is this value
        plus dedicatedSwap.sizeGB (0 if dedicatedSwap is disabled) — Linux has
        no true per-cgroup swap *reservation*, only a cap, so this bounds
        Ollama's swap usage rather than reserving the dedicated file
        exclusively for it.
      '';
    };
  };

  config = mkIf cfg.enable {
    # Works with either daemon; the host runs rootless docker (no docker group
    # needed — the daemon runs as the user). Rootful remains acceptable.
    assertions = [{
      assertion = config.virtualisation.docker.enable || config.virtualisation.docker.rootless.enable;
      message = "services.ollamaAgentic needs docker: enable virtualisation.docker or virtualisation.docker.rootless.";
    }];

    # User groups (docker group intentionally NOT granted: root-equivalent,
    # and unnecessary under rootless docker)
    users.users.${userName}.extraGroups =
      optionals (effectiveAcceleration == "rocm") [ "video" "render" ];

    # Required packages (docker CLI comes from virtualisation.docker on PATH;
    # listing pkgs.docker here pulled the insecure docker_28 default)
    environment.systemPackages = with pkgs; [
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

    # AI-dedicated overflow tier — separate from the generic backup swap in
    # configuration.nix. This is a list-type option so it merges with that
    # one automatically; NixOS's `size`-based auto-creation handles the file
    # since dedicatedSwap.path lives on the (always-mounted) root ext4 fs.
    swapDevices = lib.optional cfg.dedicatedSwap.enable {
      device = cfg.dedicatedSwap.path;
      size = cfg.dedicatedSwap.sizeGB * 1024;
      priority = cfg.dedicatedSwap.priority;
    };

    # Firewall for LAN access — explicit opt-in only; a non-loopback bind no
    # longer silently opens the port.
    networking.firewall.allowedTCPPorts =
      mkIf (cfg.network.openFirewall && cfg.network.bindAddress != "127.0.0.1") [ 11434 ];

    # Shell aliases
    environment.shellAliases = {
      ai = "ai-stack";
      ollama-start = "ai-stack start";
      ollama-stop = "ai-stack stop";
      ollama-logs = "ai-stack logs";
    };
  };
}

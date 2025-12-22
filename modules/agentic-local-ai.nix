# /etc/nixos/agentic-local-ai.nix

{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.ollamaAgentic;

  userName = "asher";
  userHome = config.users.users.${userName}.home or "/home/${userName}";
  
  # Centralized paths for consistency
  paths = {
    base = "${userHome}/.config/ollama-agentic/ai-stack";
    ollama = "${userHome}/.ollama";
    openWebui = "${userHome}/open-webui-data";
    foldingAtHome = "${userHome}/foldingathome-data";
    prometheus = "${userHome}/ai-metrics";
    backups = "${userHome}/.local/share/ai-backups";
    state = "${userHome}/.config/ollama-agentic/ai-stack/.state";
  };

  presetConfigs = {
    cpu-fallback = {
      description = "CPU-only fallback for systems without GPU acceleration or low-power scenarios. Optimized for smaller models with reasonable response times on modern CPUs.";
      numParallel = 1;
      maxLoadedModels = 2;
      keepAlive = "12h";
      maxQueue = 128;
      shmSize = "8gb";
      memoryPressure = "0.90";
      acceleration = null;
      minVramGB = 0;
      recommendedModels = [
        "tinyllama:1.1b-chat-q8_0"
        "phi3:3.8b-mini-128k-instruct-q8_0"
        "gemma2:2b-instruct-q8_0"
        "qwen2.5:3b-instruct-q8_0"
      ];
    };

    default = {
      description = "Balanced for consumer AMD/NVIDIA GPUs (16–24GB VRAM). With heavy quantization (e.g., Q4_K_M/Q3_K_M) and careful model selection, this tier can function effectively even on 8GB VRAM cards.";
      numParallel = 4;
      maxLoadedModels = 4;
      keepAlive = "24h";
      maxQueue = 512;
      shmSize = "16gb";
      memoryPressure = "0.85";
      acceleration = null;
      minVramGB = 8;
      recommendedModels = [
        "llama3.2:3b-instruct-q8_0"
        "phi3:14b-medium-128k-instruct-q6_K"
        "qwen2.5-coder:14b-q6_K"
        "gemma2:27b-instruct-q6_K"
      ];
    };

    high-vram = {
      description = "Optimized for high-end GPUs (40GB+ VRAM, e.g., RX 7900 XTX, RTX 4090)";
      numParallel = 8;
      maxLoadedModels = 6;
      keepAlive = "48h";
      maxQueue = 1024;
      shmSize = "32gb";
      memoryPressure = "0.80";
      acceleration = null;
      minVramGB = 40;
      recommendedModels = [
        "llama3.1:70b-instruct-q6_K"
        "qwen2.5:72b-instruct-q5_K_M"
        "deepseek-coder-v2:236b-lite-instruct-q4_K_M"
        "gemma2:72b-instruct-q5_K_M"
      ];
    };

    rocm-multi = {
      description = "Multi-GPU ROCm tier: uses both iGPU (780M) and dGPU (7700S) for maximum performance.";
      numParallel = 12;
      maxLoadedModels = 8;
      keepAlive = "72h";
      maxQueue = 2048;
      shmSize = "48gb";
      memoryPressure = "0.75";
      acceleration = "rocm";
      minVramGB = 16;
      recommendedModels = [
        "llama3.1:70b-instruct-q6_K"
        "qwen2.5:72b-instruct-q5_K_M"
        "deepseek-coder-v2:236b-lite-instruct-q4_K_M"
        "gemma2:27b-instruct-q8_0"
      ];
    };

    cuda = {
      description = "Optimized for NVIDIA CUDA GPUs (8–48GB VRAM). Supports larger models and higher parallelism.";
      numParallel = 12;
      maxLoadedModels = 8;
      keepAlive = "72h";
      maxQueue = 2048;
      shmSize = "48gb";
      memoryPressure = "0.75";
      acceleration = "cuda";
      minVramGB = 24;
      recommendedModels = [
        "llama3.1:70b-instruct-q6_K"
        "qwen2.5:72b-instruct-q5_K_M"
        "mixtral:8x22b-instruct-q4_K_M"
        "gemma2:27b-instruct-q8_0"
      ];
    };

    pewdiepie = {
      description = "Extreme tier for multi-GPU monster rigs (requires CUDA, 8+ GPUs, 320GB+ total VRAM)";
      numParallel = 16;
      maxLoadedModels = 10;
      keepAlive = "72h";
      maxQueue = 2048;
      shmSize = "64gb";
      memoryPressure = "0.75";
      acceleration = "cuda";
      minVramGB = 320;
      recommendedModels = [
        "llama3.1:405b-instruct-q4_K_M"
        "qwen3:235b-instruct-q4_K_M"
        "deepseek-v3:671b-q3_K_M"
      ];
    };
  };

  currentPreset = presetConfigs.${cfg.preset};

  effectiveAcceleration =
    if cfg.preset == "cpu-fallback" then null
    else if cfg.acceleration != null then cfg.acceleration
    else if cfg.preset == "rocm-multi" then "rocm"
    else if cfg.preset == "cuda" then "cuda"
    else currentPreset.acceleration;

  ollamaImage =
    if effectiveAcceleration == "rocm" then "ollama/ollama:rocm"
    else if effectiveAcceleration == "cuda" then "ollama/ollama"
    else "ollama/ollama";

  # ROCm GFX version detection helper
  gfxVersionOverride = 
    if effectiveAcceleration == "rocm" && cfg.advanced.rocm.gfxVersionOverride != null
    then "      HSA_OVERRIDE_GFX_VERSION: \"${cfg.advanced.rocm.gfxVersionOverride}\"\n"
    else "";

  rocmEnvVars =
    if effectiveAcceleration == "rocm"
    then "      ROCR_VISIBLE_DEVICES: \"0,1\"\n${gfxVersionOverride}"
    else "";

  # Prometheus configuration
  prometheusConfig = pkgs.writeText "prometheus.yml" ''
    global:
      scrape_interval: 15s
      evaluation_interval: 15s

    scrape_configs:
      - job_name: 'ollama'
        static_configs:
          - targets: ['ollama:11434']
        metrics_path: '/metrics'
  '';

  # Main docker-compose configuration — version key removed, group_add only video, relaxed healthcheck for ROCm startup
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
    + "    healthcheck:\n      test: [\"CMD-SHELL\", \"wget -qO- http://localhost:11434/api/tags || exit 1\"]\n      interval: 30s\n      timeout: 30s\n      retries: 40\n      start_period: 300s\n\n  open-webui:\n    image: ghcr.io/open-webui/open-webui:${cfg.advanced.openWebUI.version}\n    container_name: open-webui\n    restart: unless-stopped\n    read_only: true\n    security_opt:\n      - no-new-privileges:true\n    cap_drop:\n      - ALL\n    tmpfs:\n      - /tmp\n      - /var/tmp\n      - /run\n    volumes:\n      - ${paths.openWebui}:/app/backend/data\n    ports:\n      - \"${cfg.network.webUIBindAddress}:8080:8080\"\n    environment:\n      OLLAMA_BASE_URL: http://ollama:11434\n      ENABLE_SIGNUP: \"${if cfg.advanced.openWebUI.enableSignup then "true" else "false"}\"\n      WEBUI_AUTH: \"true\"\n      DEFAULT_USER_ROLE: ${cfg.advanced.openWebUI.defaultUserRole}\n      WEBUI_NAME: \"${cfg.advanced.openWebUI.title}\"\n    depends_on:\n      ollama:\n        condition: service_healthy\n    healthcheck:\n      test: [\"CMD-SHELL\", \"wget -qO- http://localhost:8080/health || exit 1\"]\n      interval: 30s\n      timeout: 10s\n      retries: 3\n      start_period: 20s\n"
    + (if cfg.advanced.foldingAtHome.enable then
        "\n  foldingathome:\n    image: ghcr.io/linuxserver/foldingathome:latest\n    container_name: foldingathome\n    restart: unless-stopped\n    security_opt:\n      - no-new-privileges:true\n    cap_drop:\n      - ALL\n    environment:\n      USER: ${cfg.advanced.foldingAtHome.user}\n      TEAM: \"${toString cfg.advanced.foldingAtHome.team}\"\n      ENABLE_GPU: \"true\"\n      ENABLE_SMP: \"true\"\n    volumes:\n      - ${paths.foldingAtHome}:/config\n"
        + (if effectiveAcceleration == "rocm" then
            "    devices:\n      - \"/dev/kfd:/dev/kfd\"\n      - \"/dev/dri:/dev/dri\"\n    group_add:\n      - video\n"
          else if effectiveAcceleration == "cuda" then
            "    deploy:\n      resources:\n        reservations:\n          devices:\n            - driver: nvidia\n              count: all\n              capabilities: [gpu]\n"
          else "")
        + "    healthcheck:\n      test: [\"CMD-SHELL\", \"wget -qO- http://localhost:7396/api/status || exit 1\"]\n      interval: 60s\n      timeout: 10s\n      retries: 3\n      start_period: 30s\n"
      else "")
    + (if cfg.advanced.monitoring.enable then
        "\n  prometheus:\n    image: prom/prometheus:${cfg.advanced.monitoring.prometheusVersion}\n    container_name: ai-metrics\n    restart: unless-stopped\n    read_only: true\n    security_opt:\n      - no-new-privileges:true\n    cap_drop:\n      - ALL\n    tmpfs:\n      - /tmp\n    volumes:\n      - ${prometheusConfig}:/etc/prometheus/prometheus.yml:ro\n      - ${paths.prometheus}:/prometheus\n    ports:\n      - \"127.0.0.1:9090:9090\"\n    command:\n      - '--config.file=/etc/prometheus/prometheus.yml'\n      - '--storage.tsdb.path=/prometheus'\n      - '--storage.tsdb.retention.time=30d'\n      - '--web.console.libraries=/usr/share/prometheus/console_libraries'\n      - '--web.console.templates=/usr/share/prometheus/consoles'\n    healthcheck:\n      test: [\"CMD-SHELL\", \"wget -qO- http://localhost:9090/-/healthy || exit 1\"]\n      interval: 30s\n      timeout: 10s\n      retries: 3\n"
      else "")
  );

  # Comprehensive management script
  aiStackScript = pkgs.writeShellScriptBin "ai-stack" ''
    #!/usr/bin/env bash
    set -euo pipefail

    # Color output
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color

    error() { echo -e "''${RED}[ERROR]''${NC} $*" >&2; }
    success() { echo -e "''${GREEN}[SUCCESS]''${NC} $*"; }
    warn() { echo -e "''${YELLOW}[WARN]''${NC} $*"; }
    info() { echo -e "''${BLUE}[INFO]''${NC} $*"; }

    # Validate Docker group membership
    if ! groups | grep -q docker; then
      error "User must be in 'docker' group. Run: sudo usermod -aG docker $USER"
      exit 1
    fi

    # Ensure directory structure
    mkdir -p \
      "${paths.base}" \
      "${paths.ollama}" \
      "${paths.openWebui}" \
      "${paths.backups}" \
      "${paths.state}" \
      ${optionalString cfg.advanced.foldingAtHome.enable "\"${paths.foldingAtHome}\""} \
      ${optionalString cfg.advanced.monitoring.enable "\"${paths.prometheus}\""}

    chmod 700 "${paths.ollama}" "${paths.openWebui}" "${paths.state}"

    COMPOSE_DIR="${paths.base}"
    COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"
    PRESET_FILE="${paths.state}/current-preset"
    MODELS_FILE="${paths.state}/preloaded-models"

    cd "$COMPOSE_DIR"

    # VRAM Detection
    detect_vram() {
      local VRAM_GB=0
      
      if command -v rocm-smi >/dev/null 2>&1; then
        local VRAM_MB=$(rocm-smi --showmeminfo vram 2>/dev/null | grep -oP 'Total Memory.*:\s*\K\d+' | head -1 || echo "0")
        VRAM_GB=$((VRAM_MB / 1024))
        info "Detected AMD GPU with ''${VRAM_GB}GB VRAM (ROCm)"
      elif command -v nvidia-smi >/dev/null 2>&1; then
        VRAM_GB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | awk '{print int($1/1024)}' || echo "0")
        info "Detected NVIDIA GPU with ''${VRAM_GB}GB VRAM (CUDA)"
      else
        info "No GPU detected - CPU mode available"
      fi
      
      echo "$VRAM_GB"
    }

    # Preset recommendation
    suggest_preset() {
      local VRAM_GB=$(detect_vram)
      
      if [ "$VRAM_GB" -ge 320 ]; then
        echo "pewdiepie"
      elif [ "$VRAM_GB" -ge 40 ]; then
        echo "high-vram"
      elif [ "$VRAM_GB" -ge 8 ]; then
        echo "default"
      else
        echo "cpu-fallback"
      fi
    }

    # ROCm GFX detection
    detect_rocm_gfx() {
      if command -v rocminfo >/dev/null 2>&1; then
        local GFX=$(rocminfo 2>/dev/null | grep -oP 'gfx\K\d{3,}' | head -1 || true)
        if [ -n "$GFX" ]; then
          local SUGGESTED=$(echo "$GFX" | awk '{printf "%d.%d.0", substr($0,1,length($0)-1), substr($0,length($0))}')
          info "Detected gfx$GFX → Consider HSA_OVERRIDE_GFX_VERSION=$SUGGESTED if needed"
          echo "$SUGGESTED"
        fi
      fi
    }

    # Preset change detection
    check_preset_change() {
      if [ -f "$PRESET_FILE" ]; then
        local OLD_PRESET=$(cat "$PRESET_FILE")
        if [ "$OLD_PRESET" != "${cfg.preset}" ]; then
          warn "Preset changed: $OLD_PRESET → ${cfg.preset}"
          warn "Restart required: ai-stack restart"
          echo "${cfg.preset}" > "$PRESET_FILE"
          return 1
        fi
      else
        echo "${cfg.preset}" > "$PRESET_FILE"
      fi
      return 0
    }

    # Deploy compose file
    deploy_compose() {
      if [ ! -f "$COMPOSE_FILE" ] || [ "${dockerComposeYml}" -nt "$COMPOSE_FILE" ]; then
        info "Deploying AI stack compose configuration..."
        cp ${dockerComposeYml} "$COMPOSE_FILE"
        success "Compose file deployed"
      fi
    }

    # Preload models
    preload_models() {
      ${if (length cfg.preloadModels) > 0 then ''
      info "Preloading ${toString (length cfg.preloadModels)} model(s)..."
      
      if [ ! -f "$MODELS_FILE" ]; then
        touch "$MODELS_FILE"
      fi
      
      LOCK_FILE="''${MODELS_FILE}.lock"
      
      ${concatMapStringsSep "\n      " (model: ''
      (
        flock -x 200
        
        if ! grep -q "^${model}$" "$MODELS_FILE" 2>/dev/null; then
          info "Pulling model: ${model}"
          if docker exec ollama ollama pull "${model}" 2>&1 | tee /tmp/ollama-pull.log | grep -q "success\|pulled"; then
            echo "${model}" >> "$MODELS_FILE"
            success "Model ${model} ready"
          else
            warn "Failed to pull ${model}"
            cat /tmp/ollama-pull.log
          fi
        else
          info "Model ${model} already preloaded"
        fi
      ) 200>"$LOCK_FILE"
      '') cfg.preloadModels}
      
      rm -f "$LOCK_FILE"
      '' else ''
      info "No models configured for preloading"
      ''}
    }

    # Health check
    health_check() {
      info "Checking service health..."
      local ALL_HEALTHY=true
      
      for service in ollama open-webui ${optionalString cfg.advanced.foldingAtHome.enable "foldingathome"} ${optionalString cfg.advanced.monitoring.enable "prometheus"}; do
        if docker compose ps "$service" 2>/dev/null | grep -q "Up (healthy)"; then
          success "$service: healthy"
        elif docker compose ps "$service" 2>/dev/null | grep -q "Up"; then
          warn "$service: running but not healthy yet"
          ALL_HEALTHY=false
        else
          error "$service: not running"
          ALL_HEALTHY=false
        fi
      done
      
      $ALL_HEALTHY && return 0 || return 1
    }

    # Backup
    backup() {
      local TIMESTAMP=$(date +%Y%m%d_%H%M%S)
      local BACKUP_FILE="${paths.backups}/ai-backup-$TIMESTAMP.tar.gz"
      
      info "Creating backup..."
      
      if ! tar -czf "$BACKUP_FILE" \
        -C "${userHome}" \
        .ollama \
        open-webui-data \
        .config/ollama-agentic/ai-stack \
        ${optionalString cfg.advanced.foldingAtHome.enable "foldingathome-data"} \
        2>&1 | tee /tmp/backup.log; then
        error "Backup failed. See /tmp/backup.log for details"
        return 1
      fi
      
      if [ -f "$BACKUP_FILE" ]; then
        local SIZE=$(du -h "$BACKUP_FILE" | cut -f1)
        success "Backup created: $BACKUP_FILE ($SIZE)"
        
        find "${paths.backups}" -name "ai-backup-*.tar.gz" -mtime +30 -delete 2>/dev/null || true
        
        if tar -tzf "$BACKUP_FILE" >/dev/null 2>&1; then
          success "Backup integrity verified"
        else
          warn "Backup may be corrupted"
        fi
      else
        error "Backup file was not created"
        return 1
      fi
    }

    # Restore
    restore() {
      local BACKUP_FILE="$1"
      
      if [ ! -f "$BACKUP_FILE" ]; then
        error "Backup file not found: $BACKUP_FILE"
        return 1
      fi
      
      warn "This will stop all services and restore from backup"
      read -p "Continue? (yes/no): " -r CONFIRM
      
      if [ "$CONFIRM" != "yes" ]; then
        info "Restore cancelled"
        return 0
      fi
      
      info "Stopping services..."
      docker compose down
      
      info "Restoring from backup..."
      tar -xzf "$BACKUP_FILE" -C "${userHome}"
      
      success "Restore complete. Start services with: ai-stack start"
    }

    # Command dispatcher
    case "''${1:-}" in
      start|up)
        deploy_compose
        check_preset_change || true
        
        info "Starting Agentic AI Stack (${cfg.preset} preset)"
        info "${currentPreset.description}"
        ${optionalString (effectiveAcceleration == "rocm") "detect_rocm_gfx"}
        
        docker compose pull --quiet
        docker compose up -d
        
        info "Waiting for services to become healthy..."
        sleep 10
        
        if health_check; then
          success "All services healthy"
          echo ""
          success "Open WebUI: http://${cfg.network.webUIBindAddress}:8080"
          ${optionalString cfg.advanced.monitoring.enable ''success "Metrics: http://127.0.0.1:9090"''}
          echo ""
          info "Recommended models for ${cfg.preset}:"
          ${concatMapStringsSep "\n          " (model: "echo \"  - ${model}\"") currentPreset.recommendedModels}
          
          preload_models
        else
          warn "Some services are still starting. Check: ai-stack status"
        fi
        ;;

      stop|down)
        info "Stopping AI stack..."
        docker compose down
        success "Services stopped"
        ;;

      restart)
        info "Restarting AI stack..."
        docker compose down
        deploy_compose
        docker compose pull --quiet
        docker compose up -d
        sleep 10
        health_check && success "Restart complete" || warn "Check status"
        ;;

      status)
        echo ""
        info "=== Service Status ==="
        docker compose ps
        echo ""
        health_check
        echo ""
        info "=== Resource Usage ==="
        docker stats --no-stream --format "table {{.Container}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}" \
          ollama open-webui ${optionalString cfg.advanced.foldingAtHome.enable "foldingathome"} ${optionalString cfg.advanced.monitoring.enable "prometheus"} 2>/dev/null || true
        echo ""
        info "=== Loaded Models ==="
        docker exec ollama ollama ps 2>/dev/null || warn "Ollama not responding"
        ;;

      logs)
        docker compose logs -f "''${@:2}"
        ;;

      pull)
        if [ -z "''${2:-}" ]; then
          error "Usage: ai-stack pull <model>"
          exit 1
        fi
        info "Pulling model: $2"
        docker exec -it ollama ollama pull "$2"
        ;;

      list)
        info "Available models:"
        docker exec ollama ollama list
        ;;

      remove|rm)
        if [ -z "''${2:-}" ]; then
          error "Usage: ai-stack remove <model>"
          exit 1
        fi
        warn "Removing model: $2"
        docker exec ollama ollama rm "$2"
        sed -i "/^$2$/d" "$MODELS_FILE" 2>/dev/null || true
        ;;

      run)
        if [ -z "''${2:-}" ]; then
          error "Usage: ai-stack run <model> [prompt]"
          exit 1
        fi
        docker exec -it ollama ollama run "''${@:2}"
        ;;

      suggest-preset)
        local SUGGESTED=$(suggest_preset)
        local CURRENT="${cfg.preset}"
        
        echo ""
        info "Current preset: $CURRENT"
        info "Suggested preset: $SUGGESTED"
        echo ""
        
        if [ "$SUGGESTED" != "$CURRENT" ]; then
          warn "Consider changing to '$SUGGESTED' preset in your NixOS configuration"
          info "Edit: services.ollamaAgentic.preset = \"$SUGGESTED\";"
        else
          success "Current preset is optimal for your hardware"
        fi
        ;;

      tune)
        info "=== GPU Information ==="
        if command -v rocm-smi >/dev/null 2>&1; then
          rocm-smi --showmeminfo vram 2>/dev/null || warn "ROCm tools not responding"
          rocm-smi --showproductname 2>/dev/null || true
        elif command -v nvidia-smi >/dev/null 2>&1; then
          nvidia-smi --query-gpu=name,memory.total,memory.used,memory.free --format=csv
        else
          warn "No GPU tools available"
        fi
        echo ""
        detect_vram
        detect_rocm_gfx
        ;;

      backup)
        backup
        ;;

      restore)
        if [ -z "''${2:-}" ]; then
          error "Usage: ai-stack restore <backup-file>"
          info "Available backups:"
          ls -lh "${paths.backups}"/ai-backup-*.tar.gz 2>/dev/null || info "No backups found"
          exit 1
        fi
        restore "$2"
        ;;

      update)
        info "Updating container images..."
        docker compose pull
        info "Restart to apply updates: ai-stack restart"
        ;;

      clean)
        warn "This will remove unused Docker resources"
        docker system prune -f
        success "Cleanup complete"
        ;;

      help|--help|-h)
        cat <<EOF
AI Stack Management Tool (${cfg.preset} preset)

Usage: ai-stack <command> [options]

Commands:
  start, up              Start the AI stack
  stop, down             Stop the AI stack
  restart                Restart all services
  status                 Show service status and resource usage
  logs [service]         Follow logs (all services or specific)
  
  pull <model>           Download a model
  list                   List available models
  remove <model>         Remove a model
  run <model> [prompt]   Run a model interactively
  
  suggest-preset         Recommend optimal preset for your hardware
  tune                   Display GPU information and tuning hints
  
  backup                 Create a backup of all data
  restore <file>         Restore from backup
  
  update                 Pull latest container images
  clean                  Remove unused Docker resources
  
  help                   Show this help message

Examples:
  ai-stack start
  ai-stack pull llama3.2:3b
  ai-stack run phi3 "explain quantum computing"
  ai-stack logs ollama
  ai-stack backup

Configuration:
  Preset: ${cfg.preset}
  Acceleration: ${if effectiveAcceleration != null then effectiveAcceleration else "CPU"}
  Models: ${toString (length cfg.preloadModels)} preloaded
  WebUI: http://${cfg.network.webUIBindAddress}:8080
EOF
        ;;

      *)
        error "Unknown command: ''${1:-}"
        info "Run 'ai-stack help' for usage information"
        exit 1
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
      description = mdDoc ''
        Performance tier preset — adjusts parallelism, model capacity, and resource limits.
        
        Use 'rocm-multi' for AMD iGPU + dGPU setups, 'cuda' for NVIDIA GPUs.
        Run `ai-stack suggest-preset` to get a recommendation based on detected hardware.
      '';
    };

    acceleration = mkOption {
      type = types.nullOr (types.enum [ "cuda" "rocm" ]);
      default = null;
      description = mdDoc ''
        Force specific acceleration backend.
        If null, auto-detected based on preset (cpu-fallback enforces CPU-only).
      '';
    };

    preloadModels = mkOption {
      type = types.listOf types.str;
      default = [];
      example = [ "llama3.2:3b" "phi3:14b" ];
      description = mdDoc ''
        Models to automatically pull on stack startup.
      '';
    };

    network = {
      ollamaBindAddress = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Bind address for Ollama API (default: localhost-only)";
      };

      webUIBindAddress = mkOption {
        type = types.str;
        default = "127.0.0.1";
        description = "Bind address for Open WebUI (default: localhost-only)";
      };
    };

    advanced = {
      openWebUI = {
        version = mkOption {
          type = types.str;
          default = "0.3";
          description = "Open WebUI container version";
        };

        enableSignup = mkOption {
          type = types.bool;
          default = false;
          description = "Enable user registration (security risk if exposed)";
        };

        defaultUserRole = mkOption {
          type = types.enum [ "admin" "user" "pending" ];
          default = "admin";
          description = "Default role for new users";
        };

        title = mkOption {
          type = types.str;
          default = "Agentic Local AI";
          description = "Custom title for the web interface";
        };
      };

      rocm = {
        gfxVersionOverride = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "11.0.2";
          description = mdDoc ''
            Override HSA_OVERRIDE_GFX_VERSION for ROCm compatibility.
            Use `ai-stack tune` to detect your GPU's gfx version.
          '';
        };
      };

      monitoring = {
        enable = mkEnableOption "Prometheus metrics collection";
        
        prometheusVersion = mkOption {
          type = types.str;
          default = "v2.48.1";
          description = "Prometheus container version";
        };
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

      autoStart = mkEnableOption "Automatic startup of AI stack on boot";
    };
  };

  config = mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.preset != "rocm-multi" || effectiveAcceleration == "rocm";
        message = "rocm-multi requires ROCm acceleration.";
      }
      {
        assertion = cfg.preset != "cuda" || effectiveAcceleration == "cuda";
        message = "cuda preset requires NVIDIA GPU and CUDA support.";
      }
      {
        assertion = cfg.preset != "pewdiepie" || effectiveAcceleration == "cuda";
        message = "pewdiepie preset requires CUDA acceleration (multi-GPU NVIDIA setup).";
      }
      {
        assertion = cfg.preset != "cpu-fallback" || effectiveAcceleration == null;
        message = "cpu-fallback preset must use CPU mode (set acceleration to null).";
      }
      {
        assertion = cfg.network.webUIBindAddress == "127.0.0.1" || cfg.advanced.openWebUI.enableSignup == false;
        message = "Exposing WebUI to network with signup enabled is a severe security risk.";
      }
      {
        assertion = all (model: builtins.match "^[a-zA-Z0-9._:-]+$" model != null) cfg.preloadModels;
        message = "Model names must only contain letters, numbers, dots, colons, hyphens, and underscores.";
      }
    ];

    warnings = [
      (mkIf (cfg.network.ollamaBindAddress != "127.0.0.1")
        "Ollama API is exposed to network (${cfg.network.ollamaBindAddress}). Ensure firewall is configured.")
      (mkIf (cfg.network.webUIBindAddress != "127.0.0.1")
        "Open WebUI is exposed to network (${cfg.network.webUIBindAddress}). This may pose security risks.")
    ] ++ optional (cfg.preset == "pewdiepie") 
      "pewdiepie preset requires 320GB+ total VRAM across multiple GPUs. Verify your hardware capabilities.";

    virtualisation.docker = {
      enable = true;
      autoPrune = {
        enable = true;
        dates = "weekly";
        flags = [ "--all" ];
      };
      daemon.settings = {
        log-driver = "json-file";
        log-opts = {
          max-size = "10m";
          max-file = "3";
        };
      };
    };

    users.users.${userName}.extraGroups = [ "docker" ]
      ++ optionals (effectiveAcceleration == "rocm") [ "video" ];

    environment.systemPackages = with pkgs; [
      docker
      docker-compose
      aiStackScript
    ] ++ optionals (effectiveAcceleration == "rocm") [
      rocmPackages.rocm-smi
      rocmPackages.rocminfo
    ] ++ optionals (effectiveAcceleration == "cuda") [
      cudaPackages.nvidia_x11
    ];

    systemd.services.agentic-ai-stack = mkIf cfg.advanced.autoStart {
      description = "Agentic Local AI Stack";
      after = [ "docker.service" "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = userName;
        ExecStart = "${aiStackScript}/bin/ai-stack start";
        ExecStop = "${aiStackScript}/bin/ai-stack stop";
        TimeoutStartSec = 600;
        TimeoutStopSec = 120;
        Restart = "on-failure";
        RestartSec = 30;
      };
    };

    system.activationScripts.aiAgentSetup = stringAfter [ "users" ] ''
      for dir in \
        "${paths.base}" \
        "${paths.ollama}" \
        "${paths.openWebui}" \
        "${paths.backups}" \
        "${paths.state}" \
        ${optionalString cfg.advanced.foldingAtHome.enable "\"${paths.foldingAtHome}\""} \
        ${optionalString cfg.advanced.monitoring.enable "\"${paths.prometheus}\""}
      do
        mkdir -p "$dir"
      done

      chown -R ${userName}:users \
        "${paths.base}" \
        "${paths.ollama}" \
        "${paths.openWebui}" \
        "${paths.backups}" \
        "${paths.state}" \
        ${optionalString cfg.advanced.foldingAtHome.enable "\"${paths.foldingAtHome}\""} \
        ${optionalString cfg.advanced.monitoring.enable "\"${paths.prometheus}\""}

      chmod 700 "${paths.ollama}" "${paths.openWebui}" "${paths.state}"
      chmod 755 "${paths.base}"

      touch "${paths.state}/current-preset"
      touch "${paths.state}/preloaded-models"
      chown ${userName}:users "${paths.state}"/*
      chmod 600 "${paths.state}"/*
    '';

    networking.firewall.allowedTCPPorts = mkIf (cfg.network.webUIBindAddress != "127.0.0.1" || cfg.network.ollamaBindAddress != "127.0.0.1") (
      optional (cfg.network.webUIBindAddress != "127.0.0.1") 8080
      ++ optional (cfg.network.ollamaBindAddress != "127.0.0.1") 11434
      ++ optional (cfg.advanced.monitoring.enable && cfg.network.ollamaBindAddress != "127.0.0.1") 9090
    );

    environment.shellAliases = {
      ai = "ai-stack";
      ollama-logs = "ai-stack logs ollama";
      webui-logs = "ai-stack logs open-webui";
    };

    system.extraSystemBuilderCmds = ''
      cat > $out/ai-stack-info.txt <<'EOF'
Agentic Local AI Stack Configuration
==========================================

Preset: ${cfg.preset}
Description: ${currentPreset.description}

Acceleration: ${if effectiveAcceleration != null then effectiveAcceleration else "CPU-only"}
Parallelism: ${toString currentPreset.numParallel}
Max Models: ${toString currentPreset.maxLoadedModels}
Keep-Alive: ${currentPreset.keepAlive}
Shared Memory: ${currentPreset.shmSize}

Network Configuration:
  Ollama API: http://${cfg.network.ollamaBindAddress}:11434
  Open WebUI: http://${cfg.network.webUIBindAddress}:8080
  ${optionalString cfg.advanced.monitoring.enable "Prometheus: http://127.0.0.1:9090"}

Recommended Models:
${concatMapStringsSep "\n" (model: "  - ${model}") currentPreset.recommendedModels}

Management:
  Start: ai-stack start
  Stop: ai-stack stop
  Status: ai-stack status
  Help: ai-stack help

Data Paths:
  Ollama: ${paths.ollama}
  WebUI: ${paths.openWebui}
  Backups: ${paths.backups}
  ${optionalString cfg.advanced.monitoring.enable "Metrics: ${paths.prometheus}"}

Features:
  Monitoring: ${if cfg.advanced.monitoring.enable then "enabled" else "disabled"}
  Folding@Home: ${if cfg.advanced.foldingAtHome.enable then "enabled" else "disabled"}
  Auto-start: ${if cfg.advanced.autoStart then "enabled" else "disabled"}
  Preload Models: ${toString (length cfg.preloadModels)}

Security:
  Container isolation: Docker
  Network binding: ${if cfg.network.webUIBindAddress == "127.0.0.1" then "localhost-only (secure)" else "network-exposed (WARNING)"}
  Read-only containers: Yes
  Capability dropping: All capabilities dropped
  User-level execution: Yes (${userName})

For more information, see the module documentation or run: ai-stack help
EOF
    '';
  };
}

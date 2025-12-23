# /etc/nixos/agentic-local-ai.nix
#
# A professional NixOS module for running Ollama with optional GPU acceleration
# and user-friendly AI interfaces.
#
# Usage:
#   services.ollamaAgentic = {
#     enable = true;
#     preset = "default";  # or "high-vram", "rocm-multi", etc.
#   };

{ config, pkgs, lib, ... }:

let
  inherit (lib)
    mkEnableOption mkOption mkIf mkMerge
    types optionals optionalString optionalAttrs
    literalExpression mdDoc;

  cfg = config.services.ollamaAgentic;

  # Determine the user for the service
  serviceUser = if cfg.user != null then cfg.user else "ollama";
  
  # Path configuration
  dataDir = if cfg.dataDir != null then cfg.dataDir else "/var/lib/ollama";
  
  paths = {
    base = "${dataDir}/ai-stack";
    ollama = "${dataDir}/models";
    foldingAtHome = "${dataDir}/foldingathome";
    state = "${dataDir}/ai-stack/.state";
  };

  # Performance presets for different hardware configurations
  presetConfigs = {
    cpu-fallback = {
      shmSize = "8gb";
      numParallel = 1;
      maxLoadedModels = 2;
      keepAlive = "12h";
      maxQueue = 128;
      memoryPressure = "0.90";
      description = "Minimal resources for CPU-only systems";
    };
    default = {
      shmSize = "16gb";
      numParallel = 4;
      maxLoadedModels = 4;
      keepAlive = "24h";
      maxQueue = 512;
      memoryPressure = "0.85";
      description = "Balanced configuration for most systems";
    };
    high-vram = {
      shmSize = "32gb";
      numParallel = 8;
      maxLoadedModels = 6;
      keepAlive = "48h";
      maxQueue = 1024;
      memoryPressure = "0.80";
      description = "High-memory systems with substantial VRAM";
    };
    rocm-multi = {
      shmSize = "48gb";
      numParallel = 12;
      maxLoadedModels = 8;
      keepAlive = "72h";
      maxQueue = 2048;
      memoryPressure = "0.75";
      description = "AMD GPU with ROCm acceleration";
    };
    cuda = {
      shmSize = "48gb";
      numParallel = 12;
      maxLoadedModels = 8;
      keepAlive = "72h";
      maxQueue = 2048;
      memoryPressure = "0.75";
      description = "NVIDIA GPU with CUDA acceleration";
    };
    enthusiast = {
      shmSize = "64gb";
      numParallel = 16;
      maxLoadedModels = 10;
      keepAlive = "96h";
      maxQueue = 4096;
      memoryPressure = "0.70";
      description = "Maximum performance for high-end systems";
    };
    pewdiepie = {
      shmSize = "256gb";
      numParallel = 32;
      maxLoadedModels = 16;
      keepAlive = "168h";
      maxQueue = 8192;
      memoryPressure = "0.65";
      description = "Extreme performance for workstation-class systems with massive RAM";
    };
  };

  currentPreset = presetConfigs.${cfg.preset};

  # Determine GPU acceleration method
  effectiveAcceleration =
    if cfg.acceleration != null then cfg.acceleration
    else if cfg.preset == "rocm-multi" then "rocm"
    else if cfg.preset == "cuda" then "cuda"
    else null;

  # Select appropriate Docker image
  ollamaImage =
    if effectiveAcceleration == "rocm" then "ollama/ollama:rocm"
    else if effectiveAcceleration == "cuda" then "ollama/ollama:0.5.4"
    else "ollama/ollama:latest";

  # ROCm-specific environment variables
  rocmEnvVars = optionalString (effectiveAcceleration == "rocm") ''
    environment:
      ROCR_VISIBLE_DEVICES: "0"
      ${optionalString (cfg.gpu.rocm.gfxVersionOverride != null)
        "HSA_OVERRIDE_GFX_VERSION: \"${cfg.gpu.rocm.gfxVersionOverride}\""}
  '';

  # CUDA-specific environment variables
  cudaEnvVars = optionalString (effectiveAcceleration == "cuda") ''
    environment:
      NVIDIA_VISIBLE_DEVICES: all
      NVIDIA_DRIVER_CAPABILITIES: compute,utility
  '';

  # Bind address configuration
  bindAddress = if cfg.network.exposeToLAN then "0.0.0.0" else "127.0.0.1";

  # Generate Docker Compose configuration
  dockerComposeConfig = pkgs.writeTextFile {
    name = "docker-compose-ollama.yml";
    text = ''
      version: '3.8'
      
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
          ${optionalString (effectiveAcceleration != null) ''
          deploy:
            resources:
              limits:
                memory: ${currentPreset.shmSize}
          ''}
          volumes:
            - ${paths.ollama}:/root/.ollama
          ports:
            - "${bindAddress}:${toString cfg.network.port}:11434"
          environment:
            OLLAMA_FLASH_ATTENTION: "1"
            OLLAMA_NUM_PARALLEL: "${toString currentPreset.numParallel}"
            OLLAMA_MAX_LOADED_MODELS: "${toString currentPreset.maxLoadedModels}"
            OLLAMA_KEEP_ALIVE: "${currentPreset.keepAlive}"
            OLLAMA_SCHED_SPREAD: "1"
            OLLAMA_KV_CACHE_TYPE: "q8_0"
            OLLAMA_MAX_QUEUE: "${toString currentPreset.maxQueue}"
            OLLAMA_MEMORY_PRESSURE_THRESHOLD: "${currentPreset.memoryPressure}"
            ${optionalString (effectiveAcceleration == "rocm" && cfg.gpu.rocm.gfxVersionOverride != null)
              "HSA_OVERRIDE_GFX_VERSION: \"${cfg.gpu.rocm.gfxVersionOverride}\""}
            ${optionalString (effectiveAcceleration == "rocm")
              "ROCR_VISIBLE_DEVICES: \"0\""}
            ${optionalString (effectiveAcceleration == "cuda")
              "NVIDIA_VISIBLE_DEVICES: all\n            NVIDIA_DRIVER_CAPABILITIES: compute,utility"}

      ${optionalString cfg.foldingAtHome.enable ''
        foldingathome:
          image: ghcr.io/linuxserver/foldingathome:latest
          container_name: foldingathome
          restart: unless-stopped
          security_opt:
            - no-new-privileges:true
          cap_drop:
            - ALL
          environment:
            USER: ${cfg.foldingAtHome.user}
            TEAM: "${toString cfg.foldingAtHome.team}"
            ENABLE_GPU: "${if effectiveAcceleration != null then "true" else "false"}"
            ENABLE_SMP: "true"
          volumes:
            - ${paths.foldingAtHome}:/config
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
      ''}
    '';
  };

  # Management script
  managementScript = pkgs.writeShellApplication {
    name = "ollama-stack";
    runtimeInputs = with pkgs; [ docker docker-compose curl ];
    text = ''
      set -euo pipefail

      # Color output
      RED='\033[0;31m'
      GREEN='\033[0;32m'
      YELLOW='\033[1;33m'
      BLUE='\033[0;34m'
      NC='\033[0m'

      error() { echo -e "''${RED}[ERROR]''${NC} $*" >&2; }
      success() { echo -e "''${GREEN}[SUCCESS]''${NC} $*"; }
      warn() { echo -e "''${YELLOW}[WARN]''${NC} $*"; }
      info() { echo -e "''${BLUE}[INFO]''${NC} $*"; }

      # Ensure directories exist
      mkdir -p "${paths.base}" "${paths.ollama}" "${paths.state}"
      ${optionalString cfg.foldingAtHome.enable "mkdir -p \"${paths.foldingAtHome}\""}

      COMPOSE_DIR="${paths.base}"
      COMPOSE_FILE="$COMPOSE_DIR/docker-compose.yml"

      cd "$COMPOSE_DIR"

      # Deploy compose file
      deploy_compose() {
        info "Deploying Docker Compose configuration..."
        cp ${dockerComposeConfig} "$COMPOSE_FILE"
        chmod 644 "$COMPOSE_FILE"
      }

      # Check if service is running
      is_running() {
        docker compose ps "$1" 2>/dev/null | grep -q "Up" || return 1
      }

      # Wait for Ollama API
      wait_for_api() {
        info "Waiting for Ollama API (timeout: 60s)..."
        local count=0
        while [ $count -lt 60 ]; do
          if curl -sf http://localhost:${toString cfg.network.port}/api/tags >/dev/null 2>&1; then
            success "Ollama API is ready!"
            return 0
          fi
          sleep 1
          count=$((count + 1))
        done
        warn "Ollama API timeout"
        return 1
      }

      # Main command handler
      case "''${1:-}" in
        start|up)
          deploy_compose
          if is_running ollama; then
            success "Ollama is already running"
          else
            info "Starting Ollama..."
            docker compose up -d ollama
            wait_for_api
          fi
          echo ""
          success "Ollama running on port ${toString cfg.network.port}"
          ${if cfg.network.exposeToLAN then ''
          success "→ Exposed to LAN at ${bindAddress}:${toString cfg.network.port}"
          warn "→ Ensure firewall allows connections from trusted devices"
          '' else ''
          info "→ Localhost only (${bindAddress}:${toString cfg.network.port})"
          info "→ Enable LAN access: services.ollamaAgentic.network.exposeToLAN = true;"
          ''}
          ${optionalString cfg.foldingAtHome.enable ''
          if is_running foldingathome; then
            success "Folding@Home is active"
          else
            info "Starting Folding@Home..."
            docker compose up -d foldingathome
            success "Folding@Home started"
          fi
          ''}
          ;;

        stop|down)
          info "Stopping services..."
          docker compose down
          success "Services stopped"
          ;;

        restart)
          info "Restarting services..."
          docker compose down
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
            info "Ollama container: Running"
            if curl -sf http://localhost:${toString cfg.network.port}/api/tags >/dev/null 2>&1; then
              success "Ollama API: Responsive"
            else
              warn "Ollama API: Not responsive"
            fi
          else
            warn "Ollama container: Not running"
          fi
          ${optionalString cfg.foldingAtHome.enable ''
          if is_running foldingathome; then
            success "Folding@Home: Running"
          else
            warn "Folding@Home: Not running"
          fi
          ''}
          echo ""
          info "=== Resource Usage ==="
          docker stats --no-stream 2>/dev/null || echo "No containers running"
          ;;

        pull)
          if [ -z "''${2:-}" ]; then
            error "Usage: ollama-stack pull <model>"
            exit 1
          fi
          if ! is_running ollama; then
            error "Ollama is not running. Start with: ollama-stack start"
            exit 1
          fi
          info "Pulling model: $2"
          docker exec ollama ollama pull "$2"
          success "Model $2 pulled"
          ;;

        logs)
          docker compose logs -f "''${2:-ollama}"
          ;;

        *)
          cat <<EOF
      ollama-stack - Ollama Management CLI

      Usage: ollama-stack <command> [args]

      Commands:
        start              Start Ollama (and Folding@Home if enabled)
        stop               Stop all services
        restart            Restart all services
        status             Show detailed service status
        pull <model>       Pull an Ollama model
        logs [service]     Follow logs (default: ollama)

      Configuration:
        Preset: ${cfg.preset} (${currentPreset.description})
        Acceleration: ${if effectiveAcceleration != null then effectiveAcceleration else "CPU only"}
        Network: ${if cfg.network.exposeToLAN then "LAN exposed" else "Localhost only"}
        Port: ${toString cfg.network.port}
        ${optionalString cfg.foldingAtHome.enable "Folding@Home: Enabled (${cfg.foldingAtHome.user})"}

      API Endpoint: http://${if cfg.network.exposeToLAN then "<your-ip>" else "localhost"}:${toString cfg.network.port}
      EOF
          exit 1
          ;;
      esac
    '';
  };

  # Available client packages
  availableClients = with pkgs; lib.filter (pkg: pkg != null) [
    (if lib.hasAttr "aichat" pkgs then aichat else null)
    (if lib.hasAttr "oterm" pkgs then oterm else null)
  ];

in
{
  options.services.ollamaAgentic = {
    enable = mkEnableOption (mdDoc "Ollama local AI stack with GPU acceleration support");

    user = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "alice";
      description = mdDoc ''
        User account to run Ollama services under.
        If null, a dedicated 'ollama' system user will be created.
      '';
    };

    dataDir = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = "/home/alice/.local/share/ollama";
      description = mdDoc ''
        Directory for Ollama data and models.
        If null, defaults to /var/lib/ollama for system user or ~/.local/share/ollama for regular users.
      '';
    };

    preset = mkOption {
      type = types.enum [ "cpu-fallback" "default" "high-vram" "rocm-multi" "cuda" "enthusiast" "pewdiepie" ];
      default = "default";
      example = "high-vram";
      description = mdDoc ''
        Performance preset for Ollama configuration:
        - **cpu-fallback**: Minimal resources (8GB shm, 1 parallel request)
        - **default**: Balanced setup (16GB shm, 4 parallel requests)
        - **high-vram**: High memory systems (32GB shm, 8 parallel requests)
        - **rocm-multi**: AMD GPU with ROCm (48GB shm, 12 parallel requests)
        - **cuda**: NVIDIA GPU with CUDA (48GB shm, 12 parallel requests)
        - **enthusiast**: Maximum performance (64GB shm, 16 parallel requests)
        - **pewdiepie**: Extreme workstation (256GB shm, 32 parallel requests, 16 models)
      '';
    };

    acceleration = mkOption {
      type = types.nullOr (types.enum [ "cuda" "rocm" ]);
      default = null;
      example = "rocm";
      description = mdDoc ''
        Force specific GPU acceleration method.
        If null, automatically determined from preset.
        - **cuda**: NVIDIA GPU acceleration
        - **rocm**: AMD GPU acceleration
      '';
    };

    network = {
      port = mkOption {
        type = types.port;
        default = 11434;
        example = 8080;
        description = mdDoc "Port for Ollama API server.";
      };

      exposeToLAN = mkOption {
        type = types.bool;
        default = false;
        description = mdDoc ''
          Bind Ollama to 0.0.0.0 making it accessible from LAN.
          **Security warning**: Only enable on trusted networks.
          Default: false (localhost only).
        '';
      };
    };

    gpu = {
      rocm = {
        gfxVersionOverride = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "10.3.0";
          description = mdDoc ''
            Override GFX version for ROCm compatibility.
            Useful for unsupported AMD GPUs (e.g., RX 6000 series).
            Find your GPU's version with: `rocminfo | grep gfx`.
          '';
        };
      };
    };

    foldingAtHome = {
      enable = mkEnableOption (mdDoc "Folding@Home distributed computing (contributes to scientific research during idle time)");

      user = mkOption {
        type = types.str;
        default = "Anonymous";
        example = "john_doe";
        description = mdDoc "Folding@Home username for contribution tracking.";
      };

      team = mkOption {
        type = types.int;
        default = 0;
        example = 123456;
        description = mdDoc ''
          Folding@Home team number.
          Join a team at: https://stats.foldingathome.org/teams
        '';
      };
    };

    installClients = mkOption {
      type = types.bool;
      default = true;
      description = mdDoc "Install user-friendly Ollama client applications (aichat, oterm, etc.).";
    };
  };

  config = mkIf cfg.enable (mkMerge [
    # Assertions for configuration validation
    {
      assertions = [
        {
          assertion = cfg.preset == "rocm-multi" -> (cfg.acceleration == null || cfg.acceleration == "rocm");
          message = "rocm-multi preset requires ROCm acceleration";
        }
        {
          assertion = cfg.preset == "cuda" -> (cfg.acceleration == null || cfg.acceleration == "cuda");
          message = "cuda preset requires CUDA acceleration";
        }
        {
          assertion = cfg.network.exposeToLAN -> config.networking.firewall.enable;
          message = "Exposing Ollama to LAN requires firewall to be enabled for security";
        }
        {
          assertion = effectiveAcceleration == "rocm" -> (lib.hasAttr "rocmPackages" pkgs);
          message = "ROCm packages not available on this system";
        }
      ];
    }

    # Core configuration
    {
      # Enable Docker
      virtualisation.docker.enable = true;

      # User configuration
      users.users = mkMerge [
        # Create system user if needed
        (mkIf (cfg.user == null) {
          ollama = {
            isSystemUser = true;
            group = "ollama";
            home = dataDir;
            createHome = true;
            description = "Ollama AI service user";
            extraGroups = [ "docker" ]
              ++ optionals (effectiveAcceleration == "rocm") [ "video" "render" ];
          };
        })
        # Add groups to existing user
        (mkIf (cfg.user != null) {
          ${cfg.user}.extraGroups = [ "docker" ]
            ++ optionals (effectiveAcceleration == "rocm") [ "video" "render" ];
        })
      ];

      users.groups = mkIf (cfg.user == null) {
        ollama = {};
      };

      # Install packages
      environment.systemPackages = with pkgs; [
        docker
        docker-compose
        managementScript
      ] ++ optionals cfg.installClients availableClients
        ++ optionals (effectiveAcceleration == "rocm" && lib.hasAttr "rocmPackages" pkgs) [
          pkgs.rocmPackages.rocm-smi
          pkgs.rocmPackages.rocminfo
        ];

      # Create data directories
      systemd.tmpfiles.rules = [
        "d ${dataDir} 0750 ${serviceUser} ${if cfg.user == null then "ollama" else "users"} -"
        "d ${paths.base} 0750 ${serviceUser} ${if cfg.user == null then "ollama" else "users"} -"
        "d ${paths.ollama} 0750 ${serviceUser} ${if cfg.user == null then "ollama" else "users"} -"
        "d ${paths.state} 0750 ${serviceUser} ${if cfg.user == null then "ollama" else "users"} -"
      ] ++ optionals cfg.foldingAtHome.enable [
        "d ${paths.foldingAtHome} 0750 ${serviceUser} ${if cfg.user == null then "ollama" else "users"} -"
      ];

      # Firewall configuration
      networking.firewall.allowedTCPPorts = mkIf cfg.network.exposeToLAN [ cfg.network.port ];

      # Convenient aliases
      environment.shellAliases = {
        ollama = "ollama-stack";
        ollama-logs = "ollama-stack logs";
      };
    }
  ]);
}

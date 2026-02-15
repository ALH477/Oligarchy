{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.custom.dcfIdentity;
  
in {
  options.custom.dcfIdentity = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the DeMoD Identity & Billing Service.";
    };
    
    domain = mkOption {
      type = types.str;
      default = "dcf.demod.ltd";
      description = "Public domain name for the Identity Service.";
    };
    
    port = mkOption {
      type = types.port;
      default = 4000;
      description = "Port to expose the Identity Service.";
    };
    
    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/demod-identity";
      description = "Host path for persistent SQLite storage.";
    };
    
    secretsFile = mkOption {
      type = types.path;
      description = ''
        Path to environment file containing secrets.
        Required variables: STRIPE_SECRET_KEY, DISCORD_CLIENT_SECRET
        Now managed via sops-nix - use config.sops.secrets."dcf/stripe-secret".path
      '';
      example = "/etc/nixos/secrets/dcf-id.env";
    };
    
    logLevel = mkOption {
      type = types.enum [ "error" "warn" "info" "debug" "trace" ];
      default = "info";
      description = "Rust log level for the service.";
    };
    
    memoryLimit = mkOption {
      type = types.str;
      default = "512m";
      description = "Container memory limit.";
    };
    
    cpuLimit = mkOption {
      type = types.str;
      default = "0.5";
      description = "Container CPU limit (for Argon2 hashing).";
    };
  };

  config = mkIf cfg.enable {
    # Ensure Docker is available
    virtualisation.docker.enable = true;
    
    # Ensure data directory exists with correct permissions
    # UID 10001 is the 'demod' user inside the container
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0700 10001 10001 -"
      "d ${cfg.dataDir}/backups 0700 10001 10001 -"
    ];

    virtualisation.oci-containers = {
      backend = "docker";
      
      containers.dcf-id = {
        image = "alh477/dcf-id:latest";
        autoStart = true;
        
        ports = [ "${toString cfg.port}:4000" ];

        environment = {
          BASE_URL = "https://${cfg.domain}";
          IDENTITY_PORT = "4000";
          DATABASE_URL = "sqlite:/data/identity.db";
          RUST_LOG = "dcf_id=${cfg.logLevel},tower_http=${cfg.logLevel}";
          RUST_BACKTRACE = "1";
        };

        # Note: When enabling, configure secrets via sops-nix
        # environmentFiles = [ "/run/secrets/dcf/stripe-secret" ];

        volumes = [
          "${cfg.dataDir}:/data"
        ];

        extraOptions = [
          "--init"
          "--read-only"
          "--tmpfs=/tmp"
          "--security-opt=no-new-privileges:true"
          "--cpus=${cfg.cpuLimit}"
          "--memory=${cfg.memoryLimit}"
          "--restart=unless-stopped"
          "--network=bridge"
          "--dns=1.1.1.1"
          "--dns=8.8.8.8"
          "--health-cmd=curl -f http://localhost:4000/health || exit 1"
          "--health-interval=30s"
          "--health-timeout=10s"
          "--health-retries=3"
          "--health-start-period=10s"
        ];
        
        dependsOn = [];
      };
    };
    
    # Ensure container service waits for network
    systemd.services.docker-dcf-id = {
      after = [ "network-online.target" "docker.service" ];
      wants = [ "network-online.target" ];
      requires = [ "docker.service" ];
      
      serviceConfig = {
        Restart = lib.mkForce "always";
        RestartSec = "10s";
      };
    };

    # Open firewall
    networking.firewall.allowedTCPPorts = [ cfg.port ];

    # Backup service
    systemd.services.dcf-identity-backup = {
      description = "Backup DCF Identity database";
      after = [ "docker-dcf-id.service" ];
      
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "dcf-identity-backup" ''
          set -e
          BACKUP_DIR="${cfg.dataDir}/backups"
          mkdir -p "$BACKUP_DIR"
          
          # Wait for database to be available
          for i in $(seq 1 10); do
            if [ -f "${cfg.dataDir}/identity.db" ]; then
              break
            fi
            sleep 1
          done
          
          if [ ! -f "${cfg.dataDir}/identity.db" ]; then
            echo "Database not found, skipping backup"
            exit 0
          fi
          
          # Create timestamped backup
          TIMESTAMP=$(date +%Y%m%d_%H%M%S)
          ${pkgs.sqlite}/bin/sqlite3 "${cfg.dataDir}/identity.db" \
            ".backup '$BACKUP_DIR/identity_$TIMESTAMP.db'"
          
          # Keep only last 7 backups
          ls -t "$BACKUP_DIR"/identity_*.db 2>/dev/null | tail -n +8 | xargs -r rm
          
          echo "Backup completed: $BACKUP_DIR/identity_$TIMESTAMP.db"
        '';
      };
    };
    
    systemd.timers.dcf-identity-backup = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        Persistent = true;
      };
    };
  };
}

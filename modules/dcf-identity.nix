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

	nodeIdFile = mkOption { type = types.nullOr types.path; default = null; };

    secretsFile = mkOption {
      type = types.path;
      description = "Path to file containing STRIPE and DISCORD secrets.";
    };
  };

  config = mkIf cfg.enable {
    # Ensure host directory is owned by the container's 'demod' user (UID 10001) 
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0700 10001 10001 -" 
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
          RUST_LOG = "dcf_id=info,tower_http=info"; 
        };

        environmentFiles = [ cfg.secretsFile ];

        volumes = [
          "${cfg.dataDir}:/data" # 
        ];

        extraOptions = [
          "--init" # Handles signals via tini 
          "--read-only" # Security hardening 
          "--tmpfs=/tmp"
          "--security-opt=no-new-privileges:true"
          "--cpus=0.5" # Limit CPU for Argon2 hashing 
          "--memory=512m"
        ];
      };
    };

    networking.firewall.allowedTCPPorts = [ cfg.port ];
  };
}

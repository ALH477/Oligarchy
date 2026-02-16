{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.boot-intro-api;
in {
  options.services.boot-intro-api = {
    enable = mkEnableOption "DeMoD Boot Intro Video Database API";

    package = mkOption {
      type = types.package;
      default = pkgs.mpv;  # Placeholder
      description = "The video-database-api package to use.";
    };

    port = mkOption {
      type = types.port;
      default = 8080;
      description = "API server port.";
    };

    dataDir = mkOption {
      type = types.path;
      default = "/var/lib/boot-intro-videos";
      description = "Data directory for video storage.";
    };

    backend = mkOption {
      type = types.enum [ "sqlite" "streamdb" ];
      default = "sqlite";
      description = "Database backend to use.";
    };

    bindAddress = mkOption {
      type = types.str;
      default = "0.0.0.0";
      description = "Address to bind to.";
    };

    enableUpload = mkOption {
      type = types.bool;
      default = true;
      description = "Enable video upload endpoint.";
    };

    maxUploadSize = mkOption {
      type = types.int;
      default = 500;  # MB
      description = "Maximum upload size in MB.";
    };

    corsOrigins = mkOption {
      type = types.listOf types.str;
      default = [ "*" ];
      description = "Allowed CORS origins.";
    };
  };

  config = mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0755 boot-intro-api boot-intro-api -"
      "d ${cfg.dataDir}/uploads 0755 boot-intro-api boot-intro-api -"
      "d ${cfg.dataDir}/thumbnails 0755 boot-intro-api boot-intro-api -"
    ];

    users.users.boot-intro-api = {
      isSystemUser = true;
      group = "boot-intro-api";
      home = cfg.dataDir;
      createHome = true;
    };

    users.groups.boot-intro-api = {};

    systemd.services.boot-intro-api = {
      description = "DeMoD Boot Intro Video Database API";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];

      serviceConfig = {
        Type = "simple";
        User = "boot-intro-api";
        Group = "boot-intro-api";
        WorkingDirectory = cfg.dataDir;
        ExecStart = "${cfg.package}/bin/video-database-api";

        Environment = [
          "DATABASE_BACKEND=${cfg.backend}"
          "PORT=${toString cfg.port}"
          "BIND_ADDRESS=${cfg.bindAddress}"
          "DATA_DIR=${cfg.dataDir}"
          "RUST_LOG=info"
        ];

        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ cfg.dataDir ];

        Restart = "on-failure";
        RestartSec = "5s";

        MemoryMax = "1G";
        TasksMax = 512;
      };
    };
  };
}

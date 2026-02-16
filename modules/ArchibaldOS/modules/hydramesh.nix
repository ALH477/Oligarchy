# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2025 DeMoD LLC. All rights reserved.
# HydraMesh NixOS Module - P2P networking as a containerized service
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.services.hydramesh;

  configFile = pkgs.writeText "hydramesh-config.json" (builtins.toJSON (
    {
      transport = cfg.transport;
      host = cfg.host;
      port = cfg.grpcPort;
      udp-port = cfg.udpPort;
      mode = cfg.mode;
      node-id = cfg.nodeId;
      peers = cfg.peers;
      optimization-level = cfg.optimizationLevel;
    }
    // optionalAttrs (cfg.rttThreshold != null) {
      group-rtt-threshold = cfg.rttThreshold;
    }
    // optionalAttrs (cfg.retryMax != null) {
      retry-max = cfg.retryMax;
    }
    // optionalAttrs (cfg.udpMtu != null) {
      udp-mtu = cfg.udpMtu;
    }
  ));

in {
  options.services.hydramesh = {
    enable = mkEnableOption "HydraMesh P2P networking service";

    image = mkOption {
      type = types.str;
      default = "alh477/hydramesh:latest";
      description = "Docker image for HydraMesh";
      example = "alh477/hydramesh:2.2.0";
    };

    nodeId = mkOption {
      type = types.str;
      default = config.networking.hostName;
      description = "Unique node identifier";
    };

    mode = mkOption {
      type = types.enum [ "p2p" "client" "server" ];
      default = "p2p";
      description = "Network mode";
    };

    transport = mkOption {
      type = types.enum [ "UDP" "TCP" ];
      default = "UDP";
      description = "Primary transport protocol";
    };

    host = mkOption {
      type = types.str;
      default = "0.0.0.0";
      description = "Bind address";
    };

    udpPort = mkOption {
      type = types.port;
      default = 7777;
      description = "UDP transport port for game/audio data";
    };

    grpcPort = mkOption {
      type = types.port;
      default = 50051;
      description = "gRPC API port";
    };

    peers = mkOption {
      type = types.listOf types.str;
      default = [];
      example = [ "192.168.1.100:7777" "192.168.1.101:7777" ];
      description = "List of peer addresses";
    };

    optimizationLevel = mkOption {
      type = types.ints.between 0 3;
      default = 2;
      description = "Optimization level (0-3)";
    };

    rttThreshold = mkOption {
      type = types.nullOr types.int;
      default = null;
      description = "Group RTT threshold in milliseconds";
    };

    retryMax = mkOption {
      type = types.nullOr types.int;
      default = null;
      description = "Maximum retry attempts";
    };

    udpMtu = mkOption {
      type = types.nullOr types.int;
      default = null;
      description = "UDP MTU size";
    };

    logLevel = mkOption {
      type = types.enum [ "debug" "info" "warn" "error" ];
      default = "info";
      description = "Log verbosity";
    };

    memoryLimit = mkOption {
      type = types.str;
      default = "256m";
      description = "Memory limit for HydraMesh container";
    };

    cpuLimit = mkOption {
      type = types.str;
      default = "0.8";
      description = "CPU limit for HydraMesh container (0.8 = 80%)";
    };

    hardened = mkOption {
      type = types.bool;
      default = true;
      description = "Run with hardened security options";
    };
  };

  config = mkIf cfg.enable {
    virtualisation.docker.enable = true;

    environment.etc."hydramesh/config.json".source = configFile;

    systemd.tmpfiles.rules = [
      "d /var/lib/hydramesh 0755 root root -"
      "d /var/log/hydramesh 0755 root root -"
    ];

    virtualisation.oci-containers.backend = "docker";

    virtualisation.oci-containers.containers.hydramesh = {
      image = cfg.image;
      autoStart = true;

      environment = {
        HYDRAMESH_CONFIG = "/etc/hydramesh/config.json";
      } // optionalAttrs (cfg.peers != []) {
        PEERS = concatStringsSep "," cfg.peers;
      };

      volumes = [
        "/etc/hydramesh/config.json:/etc/hydramesh/config.json:ro"
        "/var/lib/hydramesh:/data"
      ];

      ports = [
        "${toString cfg.udpPort}:7777/udp"
        "${toString cfg.grpcPort}:50051/tcp"
      ];

      extraOptions = [
        "--memory=${cfg.memoryLimit}"
        "--cpus=${cfg.cpuLimit}"
      ] 
      ++ optionals cfg.hardened [
        "--read-only"
        "--security-opt=no-new-privileges:true"
        "--cap-drop=ALL"
        "--cap-add=NET_BIND_SERVICE"
      ];
    };

    networking.firewall = mkIf config.networking.firewall.enable {
      allowedTCPPorts = [ cfg.grpcPort ];
      allowedUDPPorts = [ cfg.udpPort ];
    };

    environment.systemPackages = [
      (pkgs.writeShellScriptBin "hydramesh-logs" ''
        docker logs -f hydramesh "$@"
      '')
      (pkgs.writeShellScriptBin "hydramesh-status" ''
        echo "=== HydraMesh Status ==="
        docker run --rm ${cfg.image} status 2>/dev/null || \
          docker ps --filter name=hydramesh --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"
        echo ""
        echo "=== Container Info ==="
        docker inspect hydramesh --format '{{.State.Status}} - Up {{.State.StartedAt}}' 2>/dev/null || echo "Not running"
        echo ""
        echo "=== Recent Logs ==="
        docker logs --tail 20 hydramesh 2>/dev/null || echo "No logs available"
      '')
      (pkgs.writeShellScriptBin "hydramesh-version" ''
        docker run --rm ${cfg.image} version
      '')
      (pkgs.writeShellScriptBin "hydramesh-restart" ''
        systemctl restart docker-hydramesh
      '')
      (pkgs.writeShellScriptBin "hydramesh-pull" ''
        docker pull ${cfg.image}
        systemctl restart docker-hydramesh
      '')
    ];
  };
}

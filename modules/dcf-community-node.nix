{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.custom.dcfCommunityNode;
  tomlFormat = pkgs.formats.toml {};

  # Generate DCF configuration
  configFile = tomlFormat.generate "dcf_config.toml" {
    # Identity
    node_id = cfg.nodeId;
    id = cfg.nodeId;
    mode = "community";

    # Shim/Bridge Configuration
    shim = {
      target = "127.0.0.1:7777";
    };

    # Network Configuration
    network = {
      gateway_url = cfg.gatewayUrl;
      discovery_mode = "central";
      node_type = "community";
    };

    # Server Ports
    server = {
      bind_udp = "0.0.0.0:7777";       # HydraMesh Binary
      bind_grpc = "0.0.0.0:50051";     # gRPC Management
      bind_shim = "0.0.0.0:8888";      # Shim Listener (Zandronum/Legacy)
    };

    # Performance
    performance = {
      target_hz = cfg.targetHz;
      shim_mode = "bridge";
    };

    # SDK Compatibility
    node = { id = cfg.nodeId; node_id = cfg.nodeId; };
    dcf = { node_id = cfg.nodeId; };
  };

in {
  options.custom.dcfCommunityNode = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable the DCF Community Node.";
    };
    
    nodeId = mkOption {
      type = types.str;
      description = "Unique node identifier for the DCF network.";
      example = "my-node-001";
    };
    
    gatewayUrl = mkOption {
      type = types.str;
      default = "http://api.demod.ltd";
      description = "URL of the DCF gateway/coordinator.";
    };
    
    targetHz = mkOption {
      type = types.int;
      default = 125;
      description = "Target tick rate in Hz.";
    };
    
    cpuSet = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "CPU core(s) to pin the container to (e.g., '0,1' or '0-3').";
      example = "0";
    };
    
    openFirewall = mkOption {
      type = types.bool;
      default = true;
      description = "Whether to open firewall ports for DCF.";
    };
    
    memoryLimit = mkOption {
      type = types.str;
      default = "512m";
      description = "Container memory limit.";
    };
    
    cpuLimit = mkOption {
      type = types.str;
      default = "1.0";
      description = "Container CPU limit (cores).";
    };
  };

  config = mkIf cfg.enable {
    # Ensure Docker is available
    virtualisation.docker.enable = true;

    virtualisation.oci-containers = {
      backend = "docker";
      
      containers.dcf-sdk = {
        image = "alh477/dcf-rs:latest";
        autoStart = true;
        
        cmd = [ "--config" "/tmp/config.toml" ];
        
        ports = [
          "7777:7777/udp"   # Binary protocol
          "50051:50051/tcp" # gRPC
          "8888:8888/udp"   # Shim bridge
        ];
        
        environment = {
          RUST_LOG = "info,dcf=debug";
          RUST_BACKTRACE = "1";
        };
        
        volumes = [
          "${configFile}:/tmp/config.toml:ro"
        ];

        # Real-time optimizations
        extraOptions = [
          "--cap-add=SYS_NICE"
          "--cap-add=NET_RAW"
          "--cap-add=IPC_LOCK"
          "--ulimit=rtprio=99:99"
          "--ulimit=memlock=-1:-1"
          "--security-opt=no-new-privileges:true"
          "--cpus=${cfg.cpuLimit}"
          "--memory=${cfg.memoryLimit}"
          "--restart=unless-stopped"
          "--network=bridge"
          "--dns=1.1.1.1"
          "--dns=8.8.8.8"
        ] ++ optional (cfg.cpuSet != null) "--cpuset-cpus=${cfg.cpuSet}";
        
        # Dependencies
        dependsOn = [];
      };
    };
    
    # Ensure container service waits for network
    systemd.services.docker-dcf-sdk = {
      after = [ "network-online.target" "docker.service" ];
      wants = [ "network-online.target" ];
      requires = [ "docker.service" ];
      
      serviceConfig = {
        Restart = "always";
        RestartSec = "10s";
      };
    };

    # Firewall rules
    networking.firewall = mkIf cfg.openFirewall {
      allowedUDPPorts = [ 7777 8888 ];
      allowedTCPPorts = [ 50051 ];
    };

    # Health check timer
    systemd.services.dcf-healthcheck = {
      description = "DCF Community Node Health Check";
      after = [ "docker-dcf-sdk.service" ];
      
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "dcf-healthcheck" ''
          set -e
          
          # Check if container is running
          if ! ${pkgs.docker}/bin/docker ps --format '{{.Names}}' | grep -q '^dcf-sdk$'; then
            echo "DCF container not running, starting..."
            ${pkgs.systemd}/bin/systemctl start docker-dcf-sdk.service
            exit 0
          fi
          
          # Check container health
          STATUS=$(${pkgs.docker}/bin/docker inspect --format='{{.State.Health.Status}}' dcf-sdk 2>/dev/null || echo "none")
          
          if [ "$STATUS" = "unhealthy" ]; then
            echo "DCF container unhealthy, restarting..."
            ${pkgs.systemd}/bin/systemctl restart docker-dcf-sdk.service
          fi
        '';
      };
    };
    
    systemd.timers.dcf-healthcheck = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "5min";
        OnUnitActiveSec = "5min";
        Unit = "dcf-healthcheck.service";
      };
    };
  };
}

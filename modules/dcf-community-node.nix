{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.custom.dcfCommunityNode;
  tomlFormat = pkgs.formats.toml {};

  # Generate the official DCF configuration file
  configFile = tomlFormat.generate "dcf_config.toml" {
    # Identity & Mode
    node_id = cfg.nodeId;
    id = cfg.nodeId;
    mode = "community";

    # SHIM/BRIDGE CONFIGURATION
    shim = {
      # Internal Target: The bridge sends translated data to the binary port internally.
      # This resolves the external loopback errors you were seeing.
      target = "127.0.0.1:7777";
    };

    network = {
      gateway_url = "http://api.demod.ltd";
      discovery_mode = "central";
      node_type = "community";
    };

    server = {
      # HydraMesh Binary (Zandronum hitting this causes serialization errors)
      bind_udp = "0.0.0.0:7777";
      # gRPC Management
      bind_grpc = "0.0.0.0:50051";
      # Dedicated Shim Listener for Zandronum / Legacy Clients
      bind_shim = "0.0.0.0:8888"; 
    };

    performance = {
      target_hz = 125;
      # "bridge" mode is required for bidirectional game traffic
      shim_mode = "bridge";
    };

    # SDK Compatibility Blocks
    node = { id = cfg.nodeId; node_id = cfg.nodeId; };
    dcf = { node_id = cfg.nodeId; };
  };

in {
  options.custom.dcfCommunityNode = {
    enable = mkOption {
      type = types.bool;
      default = cfg.nodeId != "";
      description = "Enable the DCF Community Node.";
    };
    nodeId = mkOption {
      type = types.str;
      default = "alh477";
      description = "Node ID for identification.";
    };
    cpuSet = mkOption { type = types.nullOr types.str; default = null; };
    openFirewall = mkOption { type = types.bool; default = true; };
  };

  config = mkIf cfg.enable {
    virtualisation.docker.enable = true;

    virtualisation.oci-containers = {
      backend = "docker";
      containers.dcf-sdk = {
        image = "alh477/dcf-rs:latest";
        autoStart = true;
        
        # Ensure the container uses the generated production config
        cmd = [ "--config" "/tmp/config.toml" ];
        
        # Explicitly map 8888 for the Shim Bridge
        ports = [ 
          "7777:7777/udp" 
          "50051:50051/tcp" 
          "8888:8888/udp" 
        ];
        
        environment = { RUST_LOG = "info"; };
        
        volumes = [
          # Read-only mount for the config to /tmp
          "${configFile}:/tmp/config.toml:ro"
        ];

        # Real-time Kernel Capabilities
        extraOptions = [
          "--cap-add=SYS_NICE"
          "--cap-add=NET_RAW"
          "--cap-add=IPC_LOCK"
          "--ulimit=rtprio=99:99"
          "--ulimit=memlock=-1:-1"
          "--security-opt=no-new-privileges:true"
          "--cpus=1.0"
          "--memory=512m"
        ] ++ lib.optional (cfg.cpuSet != null) "--cpuset-cpus=${cfg.cpuSet}";
      };
    };

    # Open the host firewall for the new Shim port
    networking.firewall = mkIf cfg.openFirewall {
      allowedUDPPorts = [ 7777 8888 ];
      allowedTCPPorts = [ 50051 ];
    };
  };
}

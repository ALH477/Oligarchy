{ config, lib, pkgs, hydra-mesh, ... }:

with lib;

let
  cfg = config.services.dcf-mesh-agent;

  meshPythonEnv = pkgs.python3.withPackages (ps: with ps; [
    mcp
    # DCF protocol is pure stdlib in HydraMesh, no extra runtime deps needed
  ]);

  meshMcpWrapper = pkgs.writeScriptBin "dcf-mesh-mcp" ''
    #!${pkgs.runtimeShell}
    export DCF_AGENT_NAME="${cfg.agentName}"
    export DCF_AGENT_NODE_ID="${cfg.nodeId}"
    export DCF_AGENT_UDP_PORT="${toString cfg.udpPort}"
    export DCF_CHANNEL="${cfg.channel}"
    export DCF_PEERS="${concatStringsSep "," cfg.peers}"
    exec ${meshPythonEnv}/bin/python ${hydra-mesh}/matrix-bridge/mesh_mcp.py "$@"
  '';
in
{
  options.services.dcf-mesh-agent = {
    enable = mkEnableOption "DCF mesh agent-to-agent communication endpoint";

    nodeId = mkOption {
      type = types.str;
      default = "0x00A1";
      description = "DCF node ID for this agent (hex, e.g. 0x00A1)";
    };

    channel = mkOption {
      type = types.str;
      default = "duet";
      description = "DCF channel name shared with peer(s)";
    };

    udpPort = mkOption {
      type = types.port;
      default = 7801;
      description = "UDP port this agent listens on";
    };

    peers = mkOption {
      type = types.listOf types.str;
      default = [ "127.0.0.1:7802" ];
      description = "List of peer host:port pairs";
    };

    agentName = mkOption {
      type = types.str;
      default = "oligarchy-agent";
      description = "Human-readable agent name shown in mesh_status";
    };
  };

  config = mkIf cfg.enable {
    /*
      DCF Mesh Agent — persistent endpoint for agent-to-agent communication.

      Activation:
        services.dcf-mesh-agent.enable = true;

      Usage from Hermes (or any MCP client):
        1. Add the block from hermes-mcp.json to your MCP config
        2. Call mesh_status() to confirm peer appears
        3. Use mesh_send() + mesh_recv(N) pattern for reactive conversation
        4. No background loops — Hermes wakes only when you invoke it

      The service runs as a user systemd unit (linger enabled).
      Inbox messages land in /tmp/a2a_inbox.jsonl for inspection.
    */

    environment.systemPackages = [ meshMcpWrapper ];

    systemd.user.services.dcf-mesh-agent = {
      description = "DCF Mesh Agent MCP Server";
      after = [ "network.target" ];
      wantedBy = [ "default.target" ];

      serviceConfig = {
        ExecStart = "${meshMcpWrapper}/bin/dcf-mesh-mcp";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
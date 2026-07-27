{ config, lib, pkgs, hydramesh, ... }:

with lib;

###############################################################################
# ⚠ NOT PART OF THE READ-ONLY OLIGARCHY MCP SURFACE. ⚠
#
# This module wraps HydraMesh's `matrix-bridge/mesh_mcp.py`, an agent-to-agent
# messaging endpoint. It is fundamentally different from the servers in
# `.mcp.json`, and must never be added to that file:
#
#   * it BINDS A UDP SOCKET at import time (`NODE.start()` runs at module
#     scope, before any tool is called);
#   * `mesh_send()` TRANSMITS on the network, and `mesh_recv()` / `mesh_inbox()`
#     read from the wire — this is a read-write surface;
#   * it supports a streamable-HTTP transport on :8765 (`mesh_mcp.py http`).
#
# The Rust MCP workspace (`modules/mcp-servers/`) guarantees none of those
# things: it is stdio-only, read-only, and source-scanned by
# `nix build .#mcp-self-audit` to prove no crate opens a socket. Wiring this
# Python endpoint into `.mcp.json` would silently void that guarantee, so
# `mcp_self_audit` now fails the build if `dcf-mesh-mcp` appears there.
#
# For read-only mesh introspection use the `hydramesh` MCP aspect
# (`oligarchy-mcp hydramesh`) instead — see modules/mcp-servers/crates/hydramesh.
#
# Default is OFF and should stay that way unless a peer mesh endpoint is
# actually in use.
###############################################################################

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
    exec ${meshPythonEnv}/bin/python ${hydramesh}/matrix-bridge/mesh_mcp.py "$@"
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

      Usage from Hermes (or any MCP client) — in that client's OWN config,
      NOT in the repo-root .mcp.json (see the header above):
        1. Add the block from hermes-mcp.json to your MCP config
        2. Call mesh_status() to confirm peer appears
        3. Use mesh_send() + mesh_recv(N) pattern for reactive conversation
        4. No background loops — Hermes wakes only when you invoke it

      The service runs as a user systemd unit (linger enabled).
      Inbox messages land in /tmp/a2a_inbox.jsonl for inspection.
    */

    # Surfaced by oligarchy-ports-sec-mcp's `listening_ports` as a LAN-exposed
    # UDP bind. That is expected — it is the whole point of the module — but it
    # is why it is in known_endpoints.rs and why it is off by default.
    warnings = [
      ''
        services.dcf-mesh-agent is enabled: this opens a read-write, UDP-bound
        agent-to-agent endpoint on port ${toString cfg.udpPort}. It is NOT part
        of the read-only Oligarchy MCP surface and must not be added to
        .mcp.json. Use the `hydramesh` MCP aspect for read-only mesh state.
      ''
    ];

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

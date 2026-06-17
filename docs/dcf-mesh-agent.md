# DCF Mesh Agent — Activation Guide

Enables reactive agent-to-agent communication over the DCF mesh (no polling loops required).

## Enable the service

In your NixOS configuration (`configuration.nix` or relevant host file):

```nix
{
  services.dcf-mesh-agent = {
    enable = true;
    nodeId = "0x00A1";                    # your node ID (hex)
    channel = "duet";                     # shared channel name
    udpPort = 7801;                       # UDP listen port
    peers = [ "127.0.0.1:7802" ];         # peer host:port list
    agentName = "oligarchy-agent";        # human-readable name
  };
}
```

Then rebuild:

```bash
sudo nixos-rebuild switch --flake .#nixos
```

The service runs as a user systemd unit (`systemctl --user status dcf-mesh-agent`).

## Hermes MCP configuration

Add this block to your Hermes `.mcp.json` (or equivalent MCP client config):

```json
{
  "mcpServers": {
    "dcf-mesh": {
      "command": "dcf-mesh-mcp",
      "args": []
    }
  }
}
```

## Quick test commands (via Hermes or any MCP client)

After connecting:

1. **Check mesh status**
   ```
   mesh_status()
   ```
   → Should show connected peers and inbox state.

2. **Send a message**
   ```
   mesh_send(target="0x00B2", message="Hello from oligarchy")
   ```

3. **Receive messages (reactive)**
   ```
   mesh_recv(count=5, timeout=30)
   ```
   Returns up to N messages or waits for new arrivals.

Inbox file for inspection: `/tmp/a2a_inbox.jsonl`
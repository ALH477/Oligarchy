#!/usr/bin/env bash
# DCF Mesh minimal reactive conversation test
# Exercises send/recv loop without long-running background logic.
set -euo pipefail

echo "=== DCF Mesh Conversation Test ==="
echo "1. Checking mesh status..."
mesh_status || echo "(mesh_status may require MCP client)"

echo "2. Sending test message..."
mesh_send target="0x00B2" message="test-conversation-$(date +%s)" || true

echo "3. Receiving up to 3 messages (timeout 10s)..."
mesh_recv count=3 timeout=10 || true

echo "=== Test complete ==="
echo "Inspect /tmp/a2a_inbox.jsonl for received messages."
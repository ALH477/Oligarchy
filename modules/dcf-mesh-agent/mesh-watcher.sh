#!/usr/bin/env bash
# mesh-watcher.sh — block until the next DCF mesh message arrives
#
# Usage:
#   ./mesh-watcher.sh                    # wait for next message, print it
#   ./mesh-watcher.sh --inbox /tmp/foo   # custom inbox path
#
# This implements the "wake on next message" pattern from AGENT_TO_AGENT.md.
# Run your mesh listener (dcf-mesh-mcp or equivalent) in the background once.
# Fire this watcher whenever you want a single notification event.

set -euo pipefail

INBOX="${INBOX:-/tmp/a2a_inbox.jsonl}"
TIMEOUT="${TIMEOUT:-0}"   # 0 = wait forever

while [[ $# -gt 0 ]]; do
    case "$1" in
        --inbox) INBOX="$2"; shift 2 ;;
        --timeout) TIMEOUT="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--inbox PATH] [--timeout SECONDS]"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

if [[ ! -f "$INBOX" ]]; then
    touch "$INBOX"
fi

base=$(wc -l < "$INBOX" 2>/dev/null || echo 0)

if [[ "$TIMEOUT" -gt 0 ]]; then
    end=$(( $(date +%s) + TIMEOUT ))
    while :; do
        cur=$(wc -l < "$INBOX" 2>/dev/null || echo 0)
        if [[ "$cur" -gt "$base" ]]; then
            tail -n +"$((base + 1))" "$INBOX"
            exit 0
        fi
        if [[ $(date +%s) -ge "$end" ]]; then
            echo "timeout" >&2
            exit 124
        fi
        sleep 2
    done
else
    while :; do
        cur=$(wc -l < "$INBOX" 2>/dev/null || echo 0)
        if [[ "$cur" -gt "$base" ]]; then
            tail -n +"$((base + 1))" "$INBOX"
            exit 0
        fi
        sleep 2
    done
fi

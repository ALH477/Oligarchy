#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# dsp-bench — measure ArchibaldOS DSP coprocessor round-trip latency.
# Turns the README's latency claims into a reproducible figure: loop an audio
# signal out to the DSP guest and back through the NETJACK/JACK bridge and let
# jack_iodelay report the round trip.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

echo "⌁ Oligarchy — DSP latency benchmark"
echo

if ! command -v jack_iodelay >/dev/null 2>&1; then
  echo "jack_iodelay not found. Add jack2 / jack-example-tools to systemPackages."
  exit 1
fi

if ! pgrep -x jackd >/dev/null 2>&1 \
   && ! systemctl is-active --quiet dsp-netjack-bridge 2>/dev/null \
   && ! systemctl is-active --quiet dsp-jack-bridge 2>/dev/null; then
  echo "No JACK / NETJACK bridge looks active."
  echo "Arm the studio persona and start the DSP VM, then re-run:"
  echo "    oligarchy-ctl run persona-studio   &&   dsp-status"
  echo
fi

echo "Current PipeWire clock settings:"
pw-metadata -n settings 0 2>/dev/null | grep -iE "quantum|rate" || echo "  (pw-metadata unavailable)"
echo
echo "jack_iodelay is starting. In a patchbay (qpwgraph / qjackctl), connect:"
echo "    jack_iodelay:out  ->  the DSP coprocessor input"
echo "    the DSP coprocessor output  ->  jack_iodelay:in"
echo "Then read the steady round-trip figure (ms / frames) it prints. Ctrl-C to stop."
echo "─────────────────────────────────────────────────────────────────────────────"
exec jack_iodelay

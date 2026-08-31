#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# dsp-latency-loopback — settle the latency claim with a physical cable.
#
# WHY THIS EXISTS. The repo states DSP round-trip latency in four places and
# they disagree:
#
#     README line 12    ~0.38–2.66 ms round-trip
#     README line 98    1.33 ms @ 96 kHz
#     README line 102   0.38–0.58 ms @ 96 kHz / 32–64 samples (theoretical)
#     docs/architecture 0.38–0.66 ms theoretical, ~1.33 ms measured
#
# No amount of reading resolves that. A converter does. The working hypothesis
# is that 0.38 is the JACK period ALONE (32 samples @ 96 kHz = 0.333 ms), which
# excludes the converters and the USB transfer, and that 2.66 is simply 2 × 1.33
# — a measured round trip printed next to a theoretical one-way figure. This
# script is how that gets confirmed or killed.
#
# WHAT IT MEASURES, in two phases separated by moving ONE USB cable:
#
#   Phase A — both interfaces on the USB bus passed through to the DSP VM.
#             Run INSIDE the guest. The loop never leaves the VM, so this is the
#             coprocessor's own analog round trip: converter → DSP → converter.
#
#   Phase B — one interface moved to a HOST USB port. The loop now has to cross
#             the NETJACK bridge to close, so this is the full chain the README
#             headline actually describes: host → NETJACK → guest → converter →
#             cable → converter → host.
#
#   B − A is the cost of the bridge, isolated from the converters. Neither
#   number alone tells you that, which is the entire point of moving the cable.
#
# WHAT IT CANNOT TELL YOU. jack_iodelay measures the whole loop and cannot
# attribute it. USB audio moves in 1 ms frames (125 µs microframes at high
# speed) and every converter has a fixed pipeline delay, so a result well above
# the buffer arithmetic is expected and is NOT evidence of a bug. Report the
# measured figure; do not "correct" it toward the theoretical one.
#
# See also: home/apps/control-center/dsp-bench.sh — the single-phase, manually
# patched version. This one automates the connection, captures the number, and
# does the A/B.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

SECONDS_PER_RUN="${SECONDS_PER_RUN:-25}"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/oligarchy/dsp-latency"
OUT_PORT=""
IN_PORT=""
PHASE=""
ASSUME_YES=0

die()  { printf '\n\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }
note() { printf '  %s\n' "$*"; }
head1(){ printf '\n\033[1m%s\033[0m\n' "$*"; }
rule() { printf '─%.0s' $(seq 1 74); printf '\n'; }

usage() {
  cat <<'USAGE'
dsp-latency-loopback — two-phase physical round-trip measurement

  --phase a|b       run one phase only (a: inside the DSP guest, b: on the host)
  --out PORT        JACK/PipeWire playback port to drive  (the cable's SEND end)
  --in PORT         JACK/PipeWire capture port to listen on (the cable's RETURN end)
  --list            list available ports and exit
  --report          print previously recorded results and the delta, then exit
  --seconds N       how long to let jack_iodelay settle (default 25)
  -y, --yes         skip the safety confirmation (do not use with monitors live)

With no --phase, runs the guided A → move the cable → B sequence.
USAGE
}

# ── argument parsing ─────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --phase)   PHASE="${2:-}"; shift 2 ;;
    --out)     OUT_PORT="${2:-}"; shift 2 ;;
    --in)      IN_PORT="${2:-}"; shift 2 ;;
    --seconds) SECONDS_PER_RUN="${2:-}"; shift 2 ;;
    --list)    PHASE="list"; shift ;;
    --report)  PHASE="report"; shift ;;
    -y|--yes)  ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown argument: $1  (--help)" ;;
  esac
done

mkdir -p "$STATE_DIR" || die "cannot create $STATE_DIR"

# ── environment ──────────────────────────────────────────────────────────────
# Checked lazily, in `measure`, and NOT here: `--report` only reads files it
# wrote earlier, and the machine you read results on is often not the machine
# that produced them — the guest has the interfaces, the host has your editor.
# Gating the whole script on a measurement tool made the results unreadable
# wherever they were most useful.
require_iodelay() {
  command -v jack_iodelay >/dev/null 2>&1 \
    || die "jack_iodelay not found. Add jack-example-tools (or jack2) to systemPackages."
}

# jack_lsp/jack_connect come from the same package; pw-link is the PipeWire
# equivalent and is what is actually present on a PipeWire-JACK host. Prefer
# whichever exists rather than assuming the graph implementation.
if command -v jack_lsp >/dev/null 2>&1; then
  LSP() { jack_lsp; }
elif command -v pw-jack >/dev/null 2>&1; then
  LSP() { pw-jack jack_lsp; }
else
  LSP() { pw-link -o 2>/dev/null; pw-link -i 2>/dev/null; }
fi

connect() { # connect SRC DST — try both graph tools, do not care which wins
  if command -v jack_connect >/dev/null 2>&1 && jack_connect "$1" "$2" 2>/dev/null; then return 0; fi
  if command -v pw-link      >/dev/null 2>&1 && pw-link      "$1" "$2" 2>/dev/null; then return 0; fi
  return 1
}

list_ports() {
  head1 "Ports visible to the audio graph"
  LSP 2>/dev/null | sed 's/^/  /' || note "(no graph reachable — is JACK/PipeWire running here?)"
  cat <<'HINT'

  The SEND end (--out) is a *playback* port on the interface the cable leaves.
  The RETURN end (--in) is a *capture* port on the interface the cable enters.
  They must be DIFFERENT interfaces, or you are measuring a device against
  itself and the number means nothing.
HINT
}

# ── safety ───────────────────────────────────────────────────────────────────
# jack_iodelay drives a continuous sweep. Into headphones or a live monitor
# chain that is a hearing hazard, and a mis-patched loop between two interfaces
# on one desk is how feedback happens. This prompt is not boilerplate.
safety_gate() {
  [ "$ASSUME_YES" -eq 1 ] && return 0
  head1 "Before this makes a sound"
  note "jack_iodelay emits a CONTINUOUS TEST SWEEP for ${SECONDS_PER_RUN}s."
  note ""
  note "  • Take headphones OFF."
  note "  • Pull monitor/amp gain to zero, or unplug them."
  note "  • The only path that should be live is the measurement cable."
  note ""
  note "The signal is meant for a converter, not for your ears or a speaker."
  printf '\nType exactly: I HAVE MUTED THE MONITORS  '
  read -r ack
  [ "$ack" = "I HAVE MUTED THE MONITORS" ] || die "aborted — nothing was played."
}

# ── the measurement ──────────────────────────────────────────────────────────
# jack_iodelay prints a running estimate and never exits; it is run under a
# timeout and the LAST reading is taken, because the first few are garbage
# while it locks on.
measure() { # measure PHASE_LABEL -> echoes "frames ms"
  require_iodelay
  local label="$1" log; log="$(mktemp)"

  [ -n "$OUT_PORT" ] && [ -n "$IN_PORT" ] \
    || die "phase $label needs --out and --in (see --list)"

  head1 "Phase $label — measuring for ${SECONDS_PER_RUN}s"
  note "send   : $OUT_PORT"
  note "return : $IN_PORT"

  ( timeout "${SECONDS_PER_RUN}s" jack_iodelay >"$log" 2>&1 ) &
  local pid=$!
  sleep 3   # let it register its ports before wiring them

  if ! connect "jack_iodelay:out" "$OUT_PORT"; then
    kill "$pid" 2>/dev/null; die "could not connect jack_iodelay:out -> $OUT_PORT"
  fi
  if ! connect "$IN_PORT" "jack_iodelay:in"; then
    kill "$pid" 2>/dev/null; die "could not connect $IN_PORT -> jack_iodelay:in"
  fi
  note "connected; waiting for the estimate to settle…"
  wait "$pid" 2>/dev/null

  # e.g. "  4321.960 frames  90.041 ms total roundtrip latency"
  local line; line="$(grep -aE 'total roundtrip latency' "$log" | tail -1)"
  if [ -z "$line" ]; then
    printf '\n'; sed 's/^/  | /' "$log"
    rm -f "$log"
    die "jack_iodelay never reported a round trip. Usually the loop is not
     closed: check the cable, and that --out/--in are on DIFFERENT interfaces."
  fi
  rm -f "$log"

  local frames ms
  frames="$(printf '%s' "$line" | grep -oE '[0-9]+\.[0-9]+ frames' | grep -oE '[0-9.]+')"
  ms="$(printf '%s' "$line"     | grep -oE '[0-9]+\.[0-9]+ ms'     | grep -oE '[0-9.]+')"
  printf '%s %s\n' "$frames" "$ms"
}

record() { # record PHASE FRAMES MS
  {
    printf 'phase=%s\n' "$1"
    printf 'frames=%s\nms=%s\n' "$2" "$3"
    printf 'out_port=%s\nin_port=%s\n' "$OUT_PORT" "$IN_PORT"
    printf 'host=%s\nkernel=%s\n' "$(hostname)" "$(uname -r)"
    printf 'date=%s\n' "$(date -Is)"
    pw-metadata -n settings 0 2>/dev/null \
      | grep -iE 'clock.rate|clock.quantum' | sed 's/^/pw_/' || true
  } > "$STATE_DIR/phase-$1.txt"
  note "recorded → $STATE_DIR/phase-$1.txt"
}

report() {
  head1 "Results"
  local a_ms="" b_ms=""
  for p in a b; do
    local f="$STATE_DIR/phase-$p.txt"
    if [ -r "$f" ]; then
      # shellcheck disable=SC1090
      local ms frames; ms="$(grep '^ms=' "$f" | cut -d= -f2)"; frames="$(grep '^frames=' "$f" | cut -d= -f2)"
      printf '  phase %s : %8s ms   (%s frames)   %s\n' \
        "$p" "$ms" "$frames" "$(grep '^date=' "$f" | cut -d= -f2)"
      [ "$p" = a ] && a_ms="$ms" || b_ms="$ms"
    else
      printf '  phase %s : not measured\n' "$p"
    fi
  done

  if [ -n "$a_ms" ] && [ -n "$b_ms" ]; then
    rule
    awk -v a="$a_ms" -v b="$b_ms" 'BEGIN {
      printf "  guest-only round trip      : %8.3f ms\n", a
      printf "  full chain via NETJACK     : %8.3f ms\n", b
      printf "  cost of the bridge (B - A) : %8.3f ms\n", b - a
    }'
    rule
    cat <<'READ'
  How to read this:
    • A is the coprocessor's own analog round trip — converters, USB and DSP,
      with the bridge excluded. This is the honest number for a guitar rig
      whose interface is passed through to the guest.
    • B is the chain the README headline describes.
    • B - A is what NETJACK and the host stack cost, isolated. If it is small,
      the bridge is not the bottleneck and the converters are.

  Both are MEASURED figures. Quote them as such, and keep the theoretical
  buffer arithmetic clearly labelled as theoretical wherever it appears.
READ
  fi
}

# ── dispatch ─────────────────────────────────────────────────────────────────
case "$PHASE" in
  list)   list_ports; exit 0 ;;
  report) report;     exit 0 ;;
  a|b)
    safety_gate
    read -r F M < <(measure "${PHASE^^}")
    record "$PHASE" "$F" "$M"
    printf '\n  phase %s: %s ms (%s frames)\n' "$PHASE" "$M" "$F"
    exit 0
    ;;
  "") : ;;
  *) die "--phase must be a or b" ;;
esac

# ── guided run ───────────────────────────────────────────────────────────────
head1 "Oligarchy — DSP round-trip latency, measured with a cable"
cat <<'INTRO'
  Two measurements separated by moving ONE USB cable. Phase A runs where both
  interfaces are (the DSP guest); phase B runs on the host, after one interface
  has been moved to a host USB port so the loop has to cross NETJACK to close.
INTRO

safety_gate

head1 "Phase A — both interfaces on the VM-isolated USB bus"
note "Run this INSIDE the DSP guest, where both interfaces live."
note "If you are on the host right now, open a shell in the guest and run:"
note "    dsp-latency-loopback.sh --phase a --out <send> --in <return>"
printf '\nPress Enter once phase A is recorded, or Ctrl-C to stop.  '
read -r _

read -r AF AM < <(measure "A") && record a "$AF" "$AM"

# ── the cable move ───────────────────────────────────────────────────────────
rule
head1 "MOVE THE CABLE NOW"
cat <<'MOVE'
  Unplug the USB cable of the interface holding the RETURN end of the loop —
  the one feeding --in — and plug it into a HOST USB port. Leave the audio
  cable between the two interfaces exactly as it is; only the USB end moves.

  Why: with both interfaces on the passed-through bus, the guest owns the whole
  loop and NETJACK is never in the path. Moving one to the host forces the loop
  to close across the bridge, which is the only way to price the bridge
  separately from the converters.

  Afterwards, on the HOST:
    • confirm the interface enumerated there   (dmesg | tail, or arecord -l)
    • confirm the DSP guest is still running   (dsp-status)
    • re-run --list, because the port names WILL have changed
MOVE
rule
printf '\nPress Enter when the cable is moved and the interface is visible on the host.  '
read -r _

head1 "Phase B — one interface on the host, loop crossing NETJACK"
note "Port names have changed. Re-select them:"
list_ports
printf '\n  --out (send, on the guest side of the bridge) : '; read -r OUT_PORT
printf '  --in  (return, the interface you just moved) : '; read -r IN_PORT

read -r BF BM < <(measure "B") && record b "$BF" "$BM"

report

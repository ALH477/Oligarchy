#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# dsp-latency-guest — run INSIDE the ArchibaldOS DSP guest, over the serial
# console (`dsp-console` on the host, Ctrl-A X to exit).
#
# The measurement has to happen here. The host is a general-purpose kernel at
# whatever quantum PipeWire settled on; a figure taken there says nothing about
# a coprocessor whose entire claim rests on the RT kernel and the isolated core.
#
# TWO THINGS THIS GETS RIGHT THAT A CASUAL RUN DOES NOT:
#
#  1. It drives `jackd` directly with SEPARATE playback and capture devices
#     (-P / -C). That is exactly the two-interface loop: send out of one
#     converter, return into the other. It also means the graph always exposes
#     `system:playback_N` / `system:capture_N` whatever the hardware is called,
#     so auto-connecting is reliable rather than a guess at device names.
#
#  2. It runs at the settings the claim is ABOUT. The README's 0.38 ms assumes
#     32 samples @ 96 kHz. Measuring at 48 kHz/256 and comparing to that number
#     is meaningless — one period alone would be 5.33 ms. Rate and frames are
#     arguments here so the measurement can be made comparable, or deliberately
#     not, on purpose rather than by accident.
#
# `jack_iodelay` is NOT in jack2 (checked: no iodelay in its bin/) and is not in
# this guest's package list, so it is fetched with `nix shell` — no image
# rebuild. The guest has nix-command/flakes and DHCP, so this works as-is.
#
# TWO DIFFERENT INTERFACES DO NOT SHARE A WORD CLOCK. Expect xruns and a slowly
# drifting figure; that is the honest, realistic case for a guitar rig, not a
# fault. Take the median of a few runs, not one reading.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

RATE="${RATE:-96000}"; FRAMES="${FRAMES:-32}"; NPER="${NPER:-2}"; SECS="${SECS:-25}"
NIXRUN="nix shell nixpkgs#jack-example-tools -c"

say() { printf '%s\n' "$*"; }
die() { printf '\n[FAIL] %s\n' "$*" >&2; exit 1; }

case "${1:-help}" in
  devices)
    say "== playback devices (-P) =="; aplay  -l 2>/dev/null | grep '^card'
    say ""; say "== capture devices (-C) =="; arecord -l 2>/dev/null | grep '^card'
    say ""
    say "Use the hw:CARD,DEV form, e.g. hw:2,0 — and they MUST be different"
    say "cards, or you are measuring one device against itself."
    ;;

  start)   # start PLAYBACK_DEV CAPTURE_DEV
    P="${2:-}"; C="${3:-}"
    [ -n "$P" ] && [ -n "$C" ] || die "usage: $0 start hw:X,0 hw:Y,0"
    [ "$P" != "$C" ] || die "playback and capture must be different devices"
    pkill -x jackd 2>/dev/null; sleep 1
    say "starting jackd  rate=$RATE frames=$FRAMES nperiods=$NPER"
    say "  playback=$P  capture=$C"
    jackd -R -P 95 -d alsa -P "$P" -C "$C" -r "$RATE" -p "$FRAMES" -n "$NPER" \
      >/tmp/jackd.log 2>&1 &
    sleep 4
    pgrep -x jackd >/dev/null || { sed 's/^/  | /' /tmp/jackd.log; die "jackd did not start"; }
    say "jackd up. Theoretical one-way period: $(awk -v r="$RATE" -v f="$FRAMES" \
      'BEGIN{printf "%.3f", 1000*f/r}') ms"
    ;;

  measure)
    pgrep -x jackd >/dev/null || die "jackd is not running — '$0 start ...' first"
    say "measuring for ${SECS}s — a continuous sweep is about to play."
    say "MONITORS MUTED? Only the measurement cable should be live."
    printf 'type YES to proceed: '; read -r a; [ "$a" = "YES" ] || die "aborted"
    L=/tmp/iodelay.log
    ( timeout "${SECS}s" $NIXRUN jack_iodelay >"$L" 2>&1 ) & pid=$!
    sleep 6
    $NIXRUN jack_connect jack_iodelay:out system:playback_1 2>/dev/null
    $NIXRUN jack_connect system:capture_1 jack_iodelay:in  2>/dev/null
    say "connected; letting it lock on…"
    wait $pid 2>/dev/null
    R="$(grep -aE 'total roundtrip latency' "$L" | tail -1)"
    [ -n "$R" ] || { sed 's/^/  | /' "$L"; die "no reading — is the cable actually closing the loop?"; }
    say ""; say "RESULT  rate=$RATE frames=$FRAMES"; say "  $R"
    say ""
    say "  theoretical round trip (2 x period) : $(awk -v r="$RATE" -v f="$FRAMES" \
      'BEGIN{printf "%.3f", 2000*f/r}') ms"
    say "  everything above that is converters + USB + the RT stack."
    # Counted here rather than piped into a function: `say` is a shell
    # function and xargs cannot call one, so the piped form printed nothing.
    X="$(grep -ci xrun /tmp/jackd.log 2>/dev/null || echo 0)"
    say "  xruns logged by jackd: $X  (two unlocked clocks WILL produce some)"
    ;;

  *)
    cat <<'H'
usage, in order, inside the DSP guest:

  ./dsp-latency-guest.sh devices                 # pick two DIFFERENT cards
  ./dsp-latency-guest.sh start hw:2,0 hw:3,0     # playback dev, capture dev
  ./dsp-latency-guest.sh measure                 # the number

  RATE=48000 FRAMES=256 ./dsp-latency-guest.sh start hw:2,0 hw:3,0
      ^ override to compare settings; defaults are 96000/32, which is what the
        README's 0.38 ms figure assumes.
H
    ;;
esac

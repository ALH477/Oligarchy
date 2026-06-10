#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# oligarchy-warroom — live system cockpit (no Rust). Refreshes ~2s; Ctrl-C exits.
# Persona, kernel, DSP latency/rig, power, temp, AI, DCF mesh — one screen.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

THEME_JSON="$HOME/.config/demod/theme.json"
ACC="$(jq -r '.accent // "#00D4AA"' "$THEME_JSON" 2>/dev/null || echo "#00D4AA")"
hex2rgb() { printf '%d;%d;%d' "0x${1:1:2}" "0x${1:3:2}" "0x${1:5:2}"; }
A="\033[38;2;$(hex2rgb "$ACC")m"; Bold="\033[1m"; Dim="\033[2m"; Rst="\033[0m"

tput civis 2>/dev/null || true
trap 'tput cnorm 2>/dev/null || true; echo' EXIT INT TERM

hr()  { printf "${Dim}  ────────────────────────────────────────────────────────${Rst}\n"; }
row() { printf "  ${A}%-9s${Rst} %s\n" "$1" "$2"; }

dsp_latency() {
  local m q r
  m="$(pw-metadata -n settings 0 2>/dev/null)" || { echo "n/a"; return; }
  q="$(printf '%s\n' "$m" | grep "clock.force-quantum" | grep -oE "value:'[0-9]+'" | grep -oE "[0-9]+")"
  if [ -z "${q:-}" ] || [ "${q:-0}" = "0" ]; then
    q="$(printf '%s\n' "$m" | grep "clock.quantum" | grep -oE "value:'[0-9]+'" | grep -oE "[0-9]+")"
  fi
  r="$(printf '%s\n' "$m" | grep "clock.rate" | grep -oE "value:'[0-9]+'" | grep -oE "[0-9]+")"
  if [ -n "${q:-}" ] && [ -n "${r:-}" ] && [ "${r:-0}" -gt 0 ]; then
    awk -v q="$q" -v r="$r" 'BEGIN{ printf "%.2f ms  (%d/%d)", q*1000.0/r, q, r }'
  else
    echo "n/a"
  fi
}

while true; do
  clear
  printf "${Bold}${A}  ⌁ OLIGARCHY WAR ROOM${Rst}    ${Dim}%s${Rst}\n" "$(date '+%a %d %b · %H:%M:%S')"
  hr
  row "Persona" "$(cat /etc/oligarchy/persona 2>/dev/null || echo dev)"
  row "Kernel"  "$(uname -r)"
  row "Uptime"  "$(uptime -p 2>/dev/null | sed 's/^up //' || echo n/a)"
  row "Load"    "$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo n/a)"
  hr
  rig="$(systemctl --user is-active dsp-rig-runner >/dev/null 2>&1 && echo " · rig: $(cat ~/.config/oligarchy/rig 2>/dev/null || echo on)" || echo "")"
  row "DSP"     "$(dsp_latency)${rig}"
  command -v powerprofilesctl >/dev/null 2>&1 && row "Power" "$(powerprofilesctl get 2>/dev/null || echo n/a)"
  if command -v sensors >/dev/null 2>&1; then
    row "Temp" "$(sensors 2>/dev/null | awk '/^(Tctl|Tdie|Package id 0|edge):/{print $2; exit}')"
  fi
  hr
  command -v ai-stack         >/dev/null 2>&1 && row "AI"  "$(ai-stack status 2>/dev/null | head -n1 || echo n/a)"
  command -v hydramesh-status >/dev/null 2>&1 && row "DCF" "$(hydramesh-status 2>/dev/null | head -n1 || echo n/a)"
  hr
  printf "  ${Dim}refresh 2s · Ctrl-C to exit${Rst}\n"
  sleep 2
done

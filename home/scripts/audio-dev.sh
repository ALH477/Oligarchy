#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# audio-dev — switch the default audio output/input device.
#   audio-dev next|prev sink|source     cycle the default device
#   audio-dev menu      sink|source     pick from a wofi menu
#   audio-dev mute      sink|source     toggle mute on the default device
# OSD via swayosd (falls back to notify-send).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

osd() {
  if command -v swayosd-client >/dev/null 2>&1 && swayosd-client --custom-message "$1" --custom-icon audio-card 2>/dev/null; then
    :
  else
    command -v notify-send >/dev/null 2>&1 && notify-send "🔊 Audio" "$1" || echo "$1"
  fi
}

# List "id<TAB>description" for every Audio/Sink or Audio/Source node.
list_devices() { # $1 = Sink|Source
  pw-dump 2>/dev/null | jq -r --arg cls "Audio/$1" '
    .[] | select(.type=="PipeWire:Interface:Node")
        | select(.info.props["media.class"]==$cls)
        | "\(.id)\t\(.info.props["node.description"] // .info.props["node.nick"] // .info.props["node.name"])"'
}

# Current default device id.
cur_default_id() { # $1 = SINK|SOURCE
  wpctl inspect "@DEFAULT_AUDIO_$1@" 2>/dev/null | head -1 | grep -oE 'id [0-9]+' | grep -oE '[0-9]+'
}

kind() { case "$1" in sink) echo "Sink SINK";; source) echo "Source SOURCE";; *) echo "" ;; esac; }

cycle() { # $1 = sink|source   $2 = next|prev
  read -r cls D <<<"$(kind "$1")"; [ -n "$cls" ] || { echo "bad kind: $1" >&2; return 1; }
  mapfile -t rows < <(list_devices "$cls")
  [ "${#rows[@]}" -gt 0 ] || { osd "no $1 devices"; return 0; }
  local ids=() names=() r cur i idx new
  for r in "${rows[@]}"; do ids+=("${r%%$'\t'*}"); names+=("${r#*$'\t'}"); done
  cur="$(cur_default_id "$D")"
  idx=0; for i in "${!ids[@]}"; do [ "${ids[$i]}" = "${cur:-}" ] && idx=$i; done
  if [ "$2" = "prev" ]; then new=$(( (idx - 1 + ${#ids[@]}) % ${#ids[@]} )); else new=$(( (idx + 1) % ${#ids[@]} )); fi
  wpctl set-default "${ids[$new]}" 2>/dev/null || true
  osd "${1^}: ${names[$new]}"
}

pick() { # $1 = sink|source
  read -r cls _ <<<"$(kind "$1")"; [ -n "$cls" ] || return 1
  mapfile -t rows < <(list_devices "$cls")
  [ "${#rows[@]}" -gt 0 ] || { osd "no $1 devices"; return 0; }
  local chosen id
  chosen="$(printf '%s\n' "${rows[@]}" | cut -f2- | wofi --dmenu -i -p "$1")"
  [ -n "${chosen:-}" ] || return 0
  id="$(printf '%s\n' "${rows[@]}" | awk -F'\t' -v n="$chosen" '$2==n{print $1; exit}')"
  [ -n "${id:-}" ] && { wpctl set-default "$id" 2>/dev/null || true; osd "${1^}: $chosen"; }
}

mute() { # $1 = sink|source
  read -r _ D <<<"$(kind "$1")"; [ -n "$D" ] || return 1
  wpctl set-mute "@DEFAULT_AUDIO_$D@" toggle 2>/dev/null || true
  osd "${1^} mute toggled"
}

case "${1:-}" in
  next) cycle "${2:-sink}" next ;;
  prev) cycle "${2:-sink}" prev ;;
  menu) pick "${2:-sink}" ;;
  mute) mute "${2:-sink}" ;;
  *) echo "usage: audio-dev {next|prev|menu|mute} {sink|source}" >&2; exit 2 ;;
esac

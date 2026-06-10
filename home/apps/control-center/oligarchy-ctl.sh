#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# oligarchy-ctl — shared action dispatcher for the Oligarchy control center.
# Front-ends (oligarchy-menu / oligarchy-control) call:
#   oligarchy-ctl status            # live status header
#   oligarchy-ctl cats              # "id|Label" per category
#   oligarchy-ctl items <category>  # "id|Label" per action
#   oligarchy-ctl run <action-id>   # execute an action
# Kept deliberately dependency-light; system tools (ai-stack, hydramesh-*, dsp-*,
# hyprctl, powerprofilesctl, nmtui, wlogout, hyprlock) are resolved from PATH.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

FLAKE_DIR="${OLIGARCHY_FLAKE_DIR:-/etc/nixos}"
HOST="${OLIGARCHY_HOST:-nixos}"
LOCAL_FILE="$FLAKE_DIR/oligarchy-local.nix"
STATE="$HOME/.config/oligarchy/state.json"
TERM_CMD="${TERMINAL:-kitty}"

mkdir -p "$(dirname "$STATE")"
[ -f "$STATE" ] || echo '{"kernel":"zen","gpu":"amd"}' > "$STATE"

note() {
  if command -v notify-send >/dev/null 2>&1; then notify-send "⌁ Oligarchy" "$1"; else echo "$1"; fi
}

# Run a command so its output is visible: inline when we are in a terminal
# (the TUI), otherwise pop a terminal window (the Wofi front-end).
visible() {
  if [ -t 1 ]; then
    "$@"; echo; read -rn1 -p "— done, press any key —"; echo
  else
    setsid -f "$TERM_CMD" -e bash -c '"$@"; echo; read -rn1 -p "press any key"' _ "$@" >/dev/null 2>&1
  fi
}

# Open a long-running interactive command in its own terminal.
in_term() { setsid -f "$TERM_CMD" -e "$@" >/dev/null 2>&1; }

status() {
  echo "Kernel : $(uname -r)"
  echo "Host   : $HOST"
  if command -v powerprofilesctl >/dev/null 2>&1; then
    echo "Power  : $(powerprofilesctl get 2>/dev/null || echo n/a)"
  fi
  if command -v hydramesh-status >/dev/null 2>&1; then
    echo "DCF    : $(hydramesh-status 2>/dev/null | head -n1)"
  fi
  if command -v ai-stack >/dev/null 2>&1; then
    echo "AI     : $(ai-stack status 2>/dev/null | head -n1)"
  fi
}

cats() {
  cat <<'EOF'
appearance|🎨 Appearance
ai|🧠 AI Stack
dsp|🎛 Audio / DSP
dcf|🛰 DCF Fabric
network|🌐 Network
power|⚡ Power
system|⚙ System & Kernel
EOF
}

items() {
  case "$1" in
    appearance) cat <<'EOF'
theme-menu|Theme picker (wofi)
theme-next|Next theme
anim-toggle|Toggle animations
blur-toggle|Toggle blur
EOF
      ;;
    ai) cat <<'EOF'
ai-status|AI status
ai-start|Start AI stack
ai-stop|Stop AI stack
ai-pull|Pull a model…
EOF
      ;;
    dsp) cat <<'EOF'
dsp-status|DSP status
dsp-console|DSP console
dsp-netjack|Restart NETJACK
rt-check|Realtime check
EOF
      ;;
    dcf) cat <<'EOF'
dcf-status|Mesh status
dcf-logs|Mesh logs
dcf-restart|Restart node
dcf-pull|Pull updates
dcf-control|DCF control
EOF
      ;;
    network) cat <<'EOF'
net-tui|Network (nmtui)
net-edit|Connection editor
EOF
      ;;
    power) cat <<'EOF'
power-perf|Profile: performance
power-balanced|Profile: balanced
power-saver|Profile: power-saver
lock|Lock screen
logout|Power menu
EOF
      ;;
    system) cat <<'EOF'
sys-status|Show system status
kernel-zen|Kernel → zen
kernel-xanmod|Kernel → xanmod
kernel-latest|Kernel → latest
gpu-amd|GPU → amd
gpu-intel|GPU → intel
gpu-optimus|GPU → nvidia-optimus
rebuild-cmd|Copy rebuild command
EOF
      ;;
  esac
}

rebuild_cmd_copy() {
  local cmd="sudo nixos-rebuild switch --flake $FLAKE_DIR#$HOST"
  if command -v wl-copy >/dev/null 2>&1; then printf '%s' "$cmd" | wl-copy; fi
  note "Rebuild command copied: $cmd"
}

# Persist a kernel/gpu choice and regenerate the local override fragment.
set_local() { # $1=key $2=value
  local tmp kernel gpu frag
  tmp="$(mktemp)"
  jq --arg k "$1" --arg v "$2" '.[$k]=$v' "$STATE" > "$tmp" && mv "$tmp" "$STATE"
  kernel="$(jq -r '.kernel' "$STATE")"
  gpu="$(jq -r '.gpu' "$STATE")"
  frag="{ custom.kernel.variant = \"$kernel\"; custom.platform.gpu = \"$gpu\"; }"
  if { [ -e "$LOCAL_FILE" ] && [ -w "$LOCAL_FILE" ]; } || [ -w "$FLAKE_DIR" ]; then
    printf '%s\n' "$frag" > "$LOCAL_FILE"
    git -C "$FLAKE_DIR" add oligarchy-local.nix >/dev/null 2>&1 || true
    note "Set $1=$2 → wrote $LOCAL_FILE. Rebuild to apply (command copied)."
  else
    if command -v wl-copy >/dev/null 2>&1; then printf '%s' "$frag" | wl-copy; fi
    note "Set $1=$2. $FLAKE_DIR not writable — fragment copied. Save as oligarchy-local.nix, git add, then rebuild."
  fi
  rebuild_cmd_copy
}

hypr_toggle() { # toggle a boolean hyprctl option
  if ! command -v hyprctl >/dev/null 2>&1; then note "hyprctl unavailable (not a Hyprland session)"; return 0; fi
  local opt="$1" cur
  cur="$(hyprctl getoption "$opt" -j 2>/dev/null | jq -r '.int // 0')"
  if [ "$cur" = "1" ]; then hyprctl keyword "$opt" 0 >/dev/null; note "$opt → off"; else hyprctl keyword "$opt" 1 >/dev/null; note "$opt → on"; fi
}

ai_pull() {
  local m=""
  if [ -t 0 ]; then
    read -rp "Model to pull: " m
  elif command -v wofi >/dev/null 2>&1; then
    m="$(printf '' | wofi --dmenu -p 'Model to pull')"
  fi
  [ -n "${m:-}" ] && visible ai-stack pull "$m"
}

run() {
  case "$1" in
    theme-menu)     "$HOME/.config/hypr/scripts/theme-switcher.sh" menu ;;
    theme-next)     "$HOME/.config/hypr/scripts/theme-switcher.sh" ;;
    anim-toggle)    hypr_toggle animations:enabled ;;
    blur-toggle)    hypr_toggle decoration:blur:enabled ;;

    ai-status)      visible ai-stack status ;;
    ai-start)       visible ai-stack start ;;
    ai-stop)        visible ai-stack stop ;;
    ai-pull)        ai_pull ;;

    dsp-status)     visible dsp-status ;;
    dsp-console)    in_term dsp-console ;;
    dsp-netjack)    visible dsp-netjack-restart ;;
    rt-check)       visible rt-check ;;

    dcf-status)     visible hydramesh-status ;;
    dcf-logs)       in_term hydramesh-logs ;;
    dcf-restart)    visible hydramesh-restart ;;
    dcf-pull)       visible hydramesh-pull ;;
    dcf-control)    in_term dcf-control ;;

    net-tui)        in_term nmtui ;;
    net-edit)       nm-connection-editor >/dev/null 2>&1 & ;;

    power-perf)     powerprofilesctl set performance && note "Power → performance" ;;
    power-balanced) powerprofilesctl set balanced && note "Power → balanced" ;;
    power-saver)    powerprofilesctl set power-saver && note "Power → power-saver" ;;
    lock)           hyprlock ;;
    logout)         wlogout -p layer-shell ;;

    sys-status)     visible bash -c 'oligarchy-ctl status' ;;
    kernel-zen)     set_local kernel zen ;;
    kernel-xanmod)  set_local kernel xanmod ;;
    kernel-latest)  set_local kernel latest ;;
    gpu-amd)        set_local gpu amd ;;
    gpu-intel)      set_local gpu intel ;;
    gpu-optimus)    set_local gpu nvidia-optimus ;;
    rebuild-cmd)    rebuild_cmd_copy ;;

    *) note "Unknown action: $1"; return 1 ;;
  esac
}

case "${1:-}" in
  status) status ;;
  cats)   cats ;;
  items)  items "${2:-}" ;;
  run)    shift; run "$@" ;;
  *) echo "usage: oligarchy-ctl {status|cats|items <cat>|run <action>}" >&2; exit 2 ;;
esac

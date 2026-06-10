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
[ -f "$STATE" ] || echo '{}' > "$STATE"

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
  echo "Persona: $(cat /etc/oligarchy/persona 2>/dev/null || echo dev)"
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
persona|🎚 Persona
rig|🎸 DSP Rig
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
out-cycle|🔊 Output → next device
out-menu|🔊 Output → pick…
in-cycle|🎙 Input → next device
in-menu|🎙 Input → pick…
mute-out|Mute output
mute-mic|Mute mic
lat-up|Latency ↑
lat-down|Latency ↓
arm-dsp|Arm / disarm coprocessor
patchbay|Patchbay (qpwgraph)
helvum-open|Patchbay (helvum)
easyeffects-open|EasyEffects
dsp-status|DSP status
dsp-console|DSP console
dsp-netjack|Restart NETJACK
rt-check|Realtime check
dsp-bench|Benchmark DSP latency
EOF
      ;;
    persona) cat <<'EOF'
persona-show|Current persona
persona-studio|Studio — DSP, lowest latency
persona-gaming|Gaming — FPS + gamemode
persona-dev|Dev — balanced, AI on
persona-battery|Battery — endurance
persona-apps|Launch this persona's app set
layout-save|Save window layout
layout-restore|Restore window layout
EOF
      ;;
    rig)
      echo "rig-status|Current rig"
      if command -v dsp-rig >/dev/null 2>&1; then
        dsp-rig list 2>/dev/null | while read -r r; do echo "rig-$r|→ $r"; done
      else
        echo "rig-na|DSP rigs not enabled (set custom.dsp.enable)"
      fi
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
warroom|War Room dashboard
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

# Build the Nix override fragment from whatever keys are set in $STATE. Only keys
# the user explicitly changed appear, so persona/kernel/gpu choices don't clobber
# each other or the per-host platform settings.
build_fragment() {
  local frag="{ " v
  v="$(jq -r '.kernel  // empty' "$STATE")"; [ -n "$v" ] && frag+="custom.kernel.variant = \"$v\"; "
  v="$(jq -r '.gpu     // empty' "$STATE")"; [ -n "$v" ] && frag+="custom.platform.gpu = \"$v\"; "
  v="$(jq -r '.persona // empty' "$STATE")"; [ -n "$v" ] && frag+="custom.persona.active = \"$v\"; "
  frag+="}"
  printf '%s' "$frag"
}

# Persist a choice (kernel/gpu/persona) and regenerate the local override fragment.
set_local() { # $1=key $2=value
  local tmp frag
  tmp="$(mktemp)"
  jq --arg k "$1" --arg v "$2" '.[$k]=$v' "$STATE" > "$tmp" && mv "$tmp" "$STATE"
  frag="$(build_fragment)"
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

# Switch persona: apply the runtime bits instantly (power, animations, live audio
# quantum), then write custom.persona.active to oligarchy-local.nix for the
# build-time bits (kernel/DSP/AI/gamemode) and surface the rebuild command.
apply_persona() { # $1=name $2=powerprofile $3=anims(0|1) $4=quantum
  command -v powerprofilesctl >/dev/null 2>&1 && powerprofilesctl set "$2" >/dev/null 2>&1 || true
  command -v hyprctl >/dev/null 2>&1 && hyprctl keyword animations:enabled "$3" >/dev/null 2>&1 || true
  command -v pw-metadata >/dev/null 2>&1 && pw-metadata -n settings 0 clock.force-quantum "$4" >/dev/null 2>&1 || true
  set_local persona "$1"
  note "Persona → $1 (runtime applied; rebuild for kernel/DSP/AI/gamemode)."
}

# Launch the active persona's app set (/etc/oligarchy/persona-apps/<name>:
# "workspace|command" lines) onto their workspaces.
launch_persona_apps() {
  local active f ws cmd
  active="$(cat /etc/oligarchy/persona 2>/dev/null || echo dev)"
  f="/etc/oligarchy/persona-apps/$active"
  [ -r "$f" ] || { note "no app set for $active"; return 0; }
  while IFS='|' read -r ws cmd; do
    [ -n "${cmd:-}" ] && hyprctl dispatch exec "[workspace $ws silent] $cmd" >/dev/null 2>&1 || true
  done < "$f"
  note "launched the $active app set"
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
    out-cycle)      audio-dev next sink ;;
    out-menu)       audio-dev menu sink ;;
    in-cycle)       audio-dev next source ;;
    in-menu)        audio-dev menu source ;;
    mute-out)       audio-dev mute sink ;;
    mute-mic)       audio-dev mute source ;;
    lat-up)         dsp-quantum up ;;
    lat-down)       dsp-quantum down ;;
    arm-dsp)        dsp-arm toggle ;;
    patchbay)         setsid -f qpwgraph >/dev/null 2>&1 & ;;
    helvum-open)      setsid -f helvum >/dev/null 2>&1 & ;;
    easyeffects-open) setsid -f easyeffects >/dev/null 2>&1 & ;;

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

    dsp-bench)       visible dsp-bench ;;
    persona-show)    note "Persona: $(cat /etc/oligarchy/persona 2>/dev/null || echo dev)" ;;
    persona-studio)  apply_persona studio  performance 0 64 ;;
    persona-gaming)  apply_persona gaming  performance 1 256 ;;
    persona-dev)     apply_persona dev     balanced    1 256 ;;
    persona-battery) apply_persona battery power-saver 0 512 ;;
    persona-apps)    launch_persona_apps ;;
    layout-save)     visible persona-layout save ;;
    layout-restore)  visible persona-layout restore ;;

    warroom)         in_term oligarchy-warroom ;;

    rig-status)      visible bash -c 'dsp-rig status' ;;
    rig-na)          note "Enable custom.dsp in your config to use DSP rigs" ;;
    rig-*)           dsp-rig switch "${1#rig-}" && note "rig → ${1#rig-}" ;;

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

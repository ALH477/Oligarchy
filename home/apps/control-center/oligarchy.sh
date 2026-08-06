#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# oligarchy — unified command center for the War Machine.
# fzf-driven TUI that delegates to existing oligarchy-* commands.
# Run with no args for the interactive menu, or pass a subcommand.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

# ── Theme (same runtime source as oligarchy-update / oligarchy-control) ─────
THEME_JSON="$HOME/.config/demod/theme.json"
accent="#00F5D4"; fg="#EAEAEA"; bg="#1A1A2E"; purple="#8B5CF6"
green="#39FF14"; yellow="#FFE814"; red="#FF3B5C"; dim="#808080"
if [ -r "$THEME_JSON" ] && command -v jq >/dev/null 2>&1; then
  accent="$(jq -r '.accent // .borderFocus // "#00F5D4"' "$THEME_JSON" 2>/dev/null)"
  fg="$(jq -r '.text // "#EAEAEA"' "$THEME_JSON" 2>/dev/null)"
  bg="$(jq -r '.bg // "#1A1A2E"' "$THEME_JSON" 2>/dev/null)"
  purple="$(jq -r '.purple // "#8B5CF6"' "$THEME_JSON" 2>/dev/null)"
  green="$(jq -r '.success // "#39FF14"' "$THEME_JSON" 2>/dev/null)"
  yellow="$(jq -r '.warning // "#FFE814"' "$THEME_JSON" 2>/dev/null)"
  red="$(jq -r '.error // "#FF3B5C"' "$THEME_JSON" 2>/dev/null)"
  dim="$(jq -r '.textDim // "#808080"' "$THEME_JSON" 2>/dev/null)"
fi
export FZF_DEFAULT_OPTS="--height=60% --layout=reverse --border=rounded --color=fg:$fg,bg:$bg,hl:$accent,fg+:$accent,pointer:$accent,prompt:$accent,header:$purple"

hex_rgb() { printf '%d;%d;%d' "0x${1:1:2}" "0x${1:3:2}" "0x${1:5:2}"; }
CYAN=$(printf '\033[38;2;%sm' "$(hex_rgb "$accent")")
VIOLET=$(printf '\033[38;2;%sm' "$(hex_rgb "$purple")")
GREEN=$(printf '\033[38;2;%sm' "$(hex_rgb "$green")")
YELLOW=$(printf '\033[38;2;%sm' "$(hex_rgb "$yellow")")
RED=$(printf '\033[38;2;%sm' "$(hex_rgb "$red")")
DIM=$(printf '\033[38;2;%sm' "$(hex_rgb "$dim")")
BOLD=$'\033[1m'; RESET=$'\033[0m'

say()  { echo -e "$@"; }
warn() { say "  ${YELLOW}⚠${RESET}  $1"; }
ok()   { say "  ${GREEN}✔${RESET}  $1"; }
fail() { say "  ${RED}✖${RESET}  $1"; }

pick() { # pick <prompt> <line>... — one fzf choice, empty on abort
  printf '%s\n' "${@:2}" | fzf --no-multi --prompt="$1 ❯ "
}

banner() {
  clear
  say ""
  say "${CYAN}  ╔══════════════════════════════════════════════════════╗${RESET}"
  say "${CYAN}  ║${RESET}   ${VIOLET}⌁${RESET}  ${BOLD}OLIGARCHY COMMAND CENTER${RESET}                    ${CYAN}║${RESET}"
  say "${CYAN}  ║${RESET}   ${DIM}The War Machine · nerve center${RESET}                      ${CYAN}║${RESET}"
  say "${CYAN}  ╚══════════════════════════════════════════════════════╝${RESET}"
  # Live status line
  local status_line
  status_line="$(oligarchy-ctl status 2>/dev/null)" || status_line="status unavailable"
  say "  ${DIM}${status_line}${RESET}"
  say ""
}

# ── MCP aspect status gatherer ───────────────────────────────────────────────
cmd_mcp() {
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN

  # Aspect definitions: name|description|status-command|detail-command
  local -a ASPECTS=(
    "system|Kernel, host, persona, power|oligarchy-ctl status|oligarchy-ctl status"
    "ai|Ollama + Blipply + Voice|ai-stack status|ai-stack status"
    "dsp|Audio/DSP coprocessor|dsp-status|dsp-status"
    "dcf|DCF mesh + HydraMesh|hydramesh-status|hydramesh-status"
    "security|Firewall, AV, USB guard|oligarchy-security status --oneline|oligarchy-security status"
    "net|IP, egress, DNS|ip -o addr|ip addr"
    "vm|DSP VM coprocessor|oligarchy-dsp status|oligarchy-dsp status"
    "secrets|SOPS + age keys|sops-blackbox-ls|sops-blackbox-ls"
  )

  # Gather status in parallel (3s timeout per aspect)
  for entry in "${ASPECTS[@]}"; do
    IFS='|' read -r name desc status_cmd detail_cmd <<< "$entry"
    (
      if command -v "${status_cmd%% *}" >/dev/null 2>&1; then
        timeout 3 $status_cmd > "$tmpdir/$name" 2>/dev/null
      else
        echo "not available" > "$tmpdir/$name"
      fi
    ) &
  done
  wait

  # Build fzf entries: name padded + description + first line of status
  local -a entries=()
  local -a names=()
  for entry in "${ASPECTS[@]}"; do
    IFS='|' read -r name desc status_cmd detail_cmd <<< "$entry"
    local summary
    summary="$(head -1 "$tmpdir/$name" 2>/dev/null | cut -c1-55)"
    [ -z "$summary" ] && summary="${DIM}not available${RESET}"
    entries+=("$(printf '%-10s %-28s %s' "$name" "$desc" "$summary")")
    names+=("$name")
  done

  while true; do
    banner
    say "  ${VIOLET}▸ MCP ASPECT STATUS${RESET} ${DIM}— select for details, Esc to return${RESET}"
    say ""
    local choice
    choice="$(printf '%s\n' "${entries[@]}" \
      | fzf --no-multi --prompt="aspect ❯ " \
            --height=50% \
            --preview-window="hidden" \
      )"
    [ -z "$choice" ] && return 0

    # Extract the aspect name from the first field
    local selected
    selected="$(echo "$choice" | awk '{print $1}')"

    # Find the detail command for this aspect
    local detail_cmd=""
    for entry in "${ASPECTS[@]}"; do
      IFS='|' read -r name desc status_cmd dcmd <<< "$entry"
      if [ "$name" = "$selected" ]; then
        detail_cmd="$dcmd"
        break
      fi
    done

    # Show full details
    if [ -n "$detail_cmd" ] && command -v "${detail_cmd%% *}" >/dev/null 2>&1; then
      say ""
      say "${VIOLET}▸ ${selected^^}${RESET} ${DIM}— full status${RESET}"
      say ""
      $detail_cmd 2>/dev/null | less -R
    else
      say ""
      say "${YELLOW}⚠${RESET}  ${detail_cmd%% *} not available"
      read -rn1 -p "Press any key to continue..."
    fi
  done
}

# ── Subcommand dispatch ───────────────────────────────────────────────────────
usage() {
  cat <<'EOF'
usage: oligarchy <command> [args]

Commands:
  help       Interactive menu (default when no args)
  update     Guided system rearmament (oligarchy-update)
  keybinds   Hyprland keybind reference
  mcp        MCP aspect status overview
  control    Action dispatcher (fzf TUI)
  warroom    Live system dashboard
  dsp        DSP VM manager (passes args to oligarchy-dsp)
  security   Security controls (passes args to oligarchy-security)
  rebuild    NixOS rebuild with resource caps (passes args to rebuild)
  status     Quick status summary

Short forms: h=help, u=update, k=keybinds, m=mcp, c=control,
             w=warroom, d=dsp, s=security, r=rebuild
EOF
}

case "${1:-help}" in
  help|h|-h|--help)
    banner
    choice="$(pick "command" \
      "⚔  Update        — guided system rearmament" \
      "🎛  Control       — action dispatcher (categories + actions)" \
      "🗺  War Room      — live system dashboard" \
      "🎹  Keybinds      — Hyprland keybind reference" \
      "🔌  MCP Aspects   — mesh, AI, DSP, security status overview" \
      "⚙  DSP VM        — coprocessor VM manager" \
      "🛡  Security      — security status & controls" \
      "🔨  Rebuild       — NixOS rebuild with resource caps" \
      "🏳  Quit")"
    case "$choice" in
      "⚔"*)  exec oligarchy-update ;;
      "🎛"*)  exec oligarchy-control ;;
      "🗺"*)  exec oligarchy-warroom ;;
      "🎹"*)  exec ~/.config/hypr/scripts/keybind-help.sh menu ;;
      "🔌"*)  cmd_mcp ;;
      "⚙"*)  shift; exec oligarchy-dsp "$@" ;;
      "🛡"*)  shift; exec oligarchy-security "$@" ;;
      "🔨"*)  shift; exec rebuild "$@" ;;
      *)      say "  ${DIM}standing down.${RESET}"; exit 0 ;;
    esac
    ;;
  update|u)  exec oligarchy-update ;;
  keybinds|k) exec ~/.config/hypr/scripts/keybind-help.sh menu ;;
  mcp|m)     cmd_mcp ;;
  control|c) exec oligarchy-control ;;
  warroom|w) exec oligarchy-warroom ;;
  dsp|d)     shift; exec oligarchy-dsp "$@" ;;
  security|sec|s) shift; exec oligarchy-security "$@" ;;
  rebuild|r) shift; exec rebuild "$@" ;;
  status)    oligarchy-ctl status ;;
  *)         echo "oligarchy: unknown command '$1'" >&2; usage; exit 2 ;;
esac

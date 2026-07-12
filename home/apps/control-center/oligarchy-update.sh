#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# oligarchy-update — guided rearmament (system update) for the War Machine.
# A staged fzf walk-through: survey → resupply inputs → forge (build) →
# arsenal delta (nvd/diff-closures) → deploy (switch/test/boot) → debrief.
# Branded at runtime from ~/.config/demod/theme.json (no rebuild needed).
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

FLAKE_DIR="${OLIGARCHY_FLAKE_DIR:-/etc/nixos}"
HOST="${OLIGARCHY_HOST:-nixos}"
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/oligarchy-update"
RESULT="$CACHE_DIR/result"
LOG="$CACHE_DIR/last-build.log"
mkdir -p "$CACHE_DIR"

# ── Theme (same runtime source as oligarchy-control) ────────────────────────
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

note() { command -v notify-send >/dev/null 2>&1 && notify-send "⌁ Oligarchy" "$1"; }
say()  { echo -e "$@"; }
warn() { say "  ${YELLOW}⚠${RESET}  $1"; }
ok()   { say "  ${GREEN}✔${RESET}  $1"; }
fail() { say "  ${RED}✖${RESET}  $1"; }
step() { say "\n${VIOLET}▸ PHASE $1${RESET} ${BOLD}$2${RESET} ${DIM}— $3${RESET}"; }

pick() { # pick <prompt> <line>... — one fzf choice, empty on abort
  printf '%s\n' "${@:2}" | fzf --no-multi --prompt="$1 ❯ "
}

banner() {
  clear
  say ""
  say "${CYAN}  ╔══════════════════════════════════════════════════════╗${RESET}"
  say "${CYAN}  ║${RESET}   ${VIOLET}⌁${RESET}  ${BOLD}OLIGARCHY REARMAMENT PROTOCOL${RESET}                     ${CYAN}║${RESET}"
  say "${CYAN}  ║${RESET}   ${DIM}guided update of the unstoppable war machine${RESET}      ${CYAN}║${RESET}"
  say "${CYAN}  ╚══════════════════════════════════════════════════════╝${RESET}"
  say "  ${DIM}flake: $FLAKE_DIR   host: $HOST${RESET}"
}

# Input names + short revs from flake.lock, for the resupply picker and delta.
lock_snapshot() {
  jq -r '.nodes | to_entries[]
         | select(.value.locked.rev? != null)
         | "\(.key) \(.value.locked.rev[0:11])"' "$FLAKE_DIR/flake.lock" 2>/dev/null
}
root_inputs() {
  jq -r '.nodes.root.inputs | keys[]' "$FLAKE_DIR/flake.lock" 2>/dev/null
}

# ── PHASE I: survey (preflight) ──────────────────────────────────────────────
banner
step "I" "MUNITIONS SURVEY" "preflight checks"

[ -f "$FLAKE_DIR/flake.nix" ] || {
  fail "no flake at $FLAKE_DIR — set OLIGARCHY_FLAKE_DIR to your Oligarchy checkout"
  exit 1
}

if git -C "$FLAKE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  dirty="$(git -C "$FLAKE_DIR" status --porcelain 2>/dev/null | wc -l)"
  if [ "$dirty" -gt 0 ]; then
    warn "war chest has $dirty uncommitted change(s) — they WILL be built in"
  else
    ok "war chest clean (git)"
  fi
else
  warn "$FLAKE_DIR is not a git repository"
fi

avail_g="$(df --output=avail -BG /nix 2>/dev/null | tail -1 | tr -dc '0-9')"
if [ -n "${avail_g:-}" ] && [ "$avail_g" -lt 15 ]; then
  warn "only ${avail_g}G free on /nix — builds have failed here before; consider 'sudo nix-collect-garbage -d'"
else
  ok "${avail_g:-?}G free on /nix"
fi

if curl -sf --max-time 3 https://cache.nixos.org/nix-cache-info >/dev/null 2>&1; then
  ok "supply lines open (cache.nixos.org reachable)"
else
  warn "cache.nixos.org unreachable — input updates/substitutions may fail"
fi

# ── PHASE II: resupply (choose + run input updates) ──────────────────────────
step "II" "SUPPLY LINES" "choose update scope"
scope="$(pick "scope" \
  "⚔  Full rearmament — update ALL flake inputs" \
  "🎯 Selective strike — pick inputs to update" \
  "🔁 Rebuild only — no input updates" \
  "🏳  Abort")"
case "$scope" in
  "⚔"*)  update_args=("--all") ;;
  "🎯"*) mapfile -t sel < <(root_inputs | fzf --multi --prompt='inputs (TAB to mark) ❯ ')
         [ "${#sel[@]}" -gt 0 ] || { fail "no inputs chosen — standing down"; exit 0; }
         update_args=("${sel[@]}") ;;
  "🔁"*) update_args=() ;;
  *)      say "  ${DIM}standing down.${RESET}"; exit 0 ;;
esac

if [ "${#update_args[@]}" -gt 0 ]; then
  before="$(lock_snapshot)"
  say "  ${DIM}nix flake update ...${RESET}"
  if [ "${update_args[0]}" = "--all" ]; then
    (cd "$FLAKE_DIR" && nix flake update) || { fail "flake update failed"; exit 1; }
  else
    (cd "$FLAKE_DIR" && nix flake update "${update_args[@]}") || { fail "flake update failed"; exit 1; }
  fi
  after="$(lock_snapshot)"
  delta="$(awk 'NR==FNR{old[$1]=$2;next} old[$1]!=$2{printf "  %-28s %s → %s\n",$1,old[$1],$2}' \
           <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"
  if [ -n "$delta" ]; then
    say "\n  ${BOLD}fresh munitions:${RESET}"
    say "${CYAN}$delta${RESET}"
  else
    ok "all inputs already at the front line (no changes)"
  fi
fi

# ── PHASE III: forge (build, no activation) ──────────────────────────────────
step "III" "FORGING THE WAR MACHINE" "building the new system (no activation yet)"
say "  ${DIM}log: $LOG${RESET}\n"
if ! nix build "$FLAKE_DIR#nixosConfigurations.$HOST.config.system.build.toplevel" \
     -o "$RESULT" 2>&1 | tee "$LOG"; then
  build_rc=1
else
  build_rc=${PIPESTATUS[0]}
fi
if [ "$build_rc" -ne 0 ]; then
  fail "the forge went cold — build failed. Last lines:"
  tail -n 15 "$LOG" | sed 's/^/    /'
  say "  ${DIM}full log: $LOG${RESET}"
  note "Rearmament failed at build. See $LOG"
  exit 1
fi
ok "war machine forged: $(readlink -f "$RESULT")"

# ── PHASE IV: arsenal delta (what actually changes) ──────────────────────────
step "IV" "ARSENAL DELTA" "current system vs. the new build"
if command -v nvd >/dev/null 2>&1; then
  nvd diff /run/current-system "$RESULT" || true
else
  nix store diff-closures /run/current-system "$RESULT" || true
fi

# ── PHASE V: deployment ───────────────────────────────────────────────────────
step "V" "DEPLOYMENT" "activate the new regime"
deploy="$(pick "deploy" \
  "🚀 switch — activate now and on every boot" \
  "🧪 test — activate now only (reverts on reboot)" \
  "🌙 boot — activate on next boot only" \
  "🏳  Abort — build kept at $RESULT")"
case "$deploy" in
  "🚀"*) mode="switch" ;;
  "🧪"*) mode="test" ;;
  "🌙"*) mode="boot" ;;
  *) say "  ${DIM}standing down — the forged system stays cached for later.${RESET}"; exit 0 ;;
esac

say "  ${DIM}sudo nixos-rebuild $mode --flake $FLAKE_DIR#$HOST${RESET}\n"
if sudo nixos-rebuild "$mode" --flake "$FLAKE_DIR#$HOST"; then
  say ""
  say "${GREEN}  ╔══════════════════════════════════════════════════════╗${RESET}"
  say "${GREEN}  ║   ⌁  REARMAMENT COMPLETE — the regime is ($mode)ed"'      '"║${RESET}"
  say "${GREEN}  ╚══════════════════════════════════════════════════════╝${RESET}"
  note "Rearmament complete ($mode)."
else
  fail "activation failed — the old regime remains in power"
  say "  ${DIM}rollback (if partially applied): sudo nixos-rebuild switch --rollback${RESET}"
  note "Rearmament failed at activation."
  exit 1
fi

# ── PHASE VI: debrief ─────────────────────────────────────────────────────────
step "VI" "DEBRIEF" "housekeeping"
if [ "${#update_args[@]}" -gt 0 ] && git -C "$FLAKE_DIR" rev-parse --git-dir >/dev/null 2>&1 \
   && ! git -C "$FLAKE_DIR" diff --quiet -- flake.lock; then
  commit="$(pick "commit flake.lock bump?" "📜 Yes — commit the lock file" "No")"
  if [ "${commit:0:1}" = "📜" ]; then
    git -C "$FLAKE_DIR" add flake.lock \
      && git -C "$FLAKE_DIR" commit -m "chore: flake input update via oligarchy-update" -- flake.lock \
      && ok "flake.lock committed"
  fi
fi
gc="$(pick "purge old generations (nix-collect-garbage -d)?" "No" "🗑 Yes — reclaim disk")"
if [ "${gc:0:1}" = "🗑" ]; then
  sudo nix-collect-garbage -d && ok "old regimes purged"
fi
say "\n  ${CYAN}⌁ the war machine marches on.${RESET}\n"

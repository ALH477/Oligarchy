#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# hypr-session — save the running Hyprland window set and RELAUNCH it later.
#
# Sibling of persona-layout, not a replacement:
#   persona-layout  moves windows that are ALREADY open onto their workspaces.
#   hypr-session    records each window's argv/cwd/exe and starts it again.
#
#   hypr-session save    [--to FILE]
#   hypr-session restore [--from FILE] [--dry-run]
#
# Default file: ~/.config/oligarchy/session/last.json
#
# --dry-run prints one `hyprctl dispatch exec ...` line per launch and starts
# nothing. It deliberately does NOT probe the filesystem (no `command -v`, no
# `-x` test, no readlink): the fixtures under home/scripts/testdata/hypr-session/
# are diffed byte-for-byte by the `hypr-session-tests` build gate, and any probe
# would make the output depend on what happens to be installed on the runner.
# Live restore does probe, and falls back to the basename of `exe` when argv[0]
# is a /nix/store path that a rebuild has since garbage-collected.
#
# HYPRCTL / JQ override the binaries; both default to a PATH lookup, which is
# what the systemd user units in home/hyprland/default.nix rely on.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

HYPRCTL="${HYPRCTL:-hyprctl}"
JQ="${JQ:-jq}"
# ${HOME:-} rather than $HOME: `set -u` would otherwise abort the whole script
# before argument parsing on a host with no HOME (a Nix build sandbox, which is
# exactly where the `hypr-session-tests` gate runs `restore --dry-run --from`).
SESSION_DIR="${HOME:-/nonexistent}/.config/oligarchy/session"
DEFAULT_FILE="$SESSION_DIR/last.json"

# Global, not `local`: the EXIT trap fires after cmd_save's frame is gone, and
# a `local` name is unbound by then -- which under `set -u` printed an error on
# every successful save.
SAVE_TMP=""
trap 'rm -f -- "${SAVE_TMP:-}"' EXIT

die() { echo "hypr-session: $1" >&2; exit "${2:-1}"; }
skip() { echo "hypr-session: skip $1: $2" >&2; }

usage() {
  cat <<'USAGE'
usage: hypr-session save    [--to FILE]
       hypr-session restore [--from FILE] [--dry-run]

Save the current Hyprland windows (class, workspace, geometry, argv, cwd) and
relaunch them later. Scratchpads and special workspaces are skipped: exec-once
already owns those.

Options:
  --to FILE     write the snapshot here      (default ~/.config/oligarchy/session/last.json)
  --from FILE   read the snapshot from here  (default as above)
  --dry-run     print the hyprctl dispatch lines, launch nothing, exit 0
  -h, --help    show this help

Environment:
  HYPRCTL       hyprctl binary (default: hyprctl on PATH)
  JQ            jq binary      (default: jq on PATH)
USAGE
}

# POSIX single-quoting. The dispatch payload is parsed by /bin/sh twice (once by
# Hyprland's exec dispatcher, once by the `sh -c` inside it), so the inner script
# has to survive being wrapped in single quotes even when it contains one.
sq() {
  local s=$1
  printf "'%s'" "${s//\'/\'\\\'\'}"
}

need_jq() { command -v "$JQ" >/dev/null 2>&1 || die "jq not found (set \$JQ)"; }

# ── save ─────────────────────────────────────────────────────────────────────
# Filters, in order: dead/kernel pids; special workspaces (negative ids — the
# dropdown scratchpads live there and exec-once respawns them); scratch-* classes;
# unmapped windows. Then one entry per pid, keeping the FIRST one seen, so a
# multi-window app (one browser, five windows) is launched exactly once.
cmd_save() {
  local out="$DEFAULT_FILE"
  while [ $# -gt 0 ]; do
    case "$1" in
      --to) [ $# -ge 2 ] || die "--to needs a FILE" 2; out="$2"; shift 2 ;;
      -h | --help) usage; exit 0 ;;
      *) echo "hypr-session: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
  done

  need_jq
  command -v "$HYPRCTL" >/dev/null 2>&1 || die "hyprctl not found — is Hyprland running? (set \$HYPRCTL)"

  local clients
  clients=$("$HYPRCTL" clients -j 2>/dev/null) || die "hyprctl clients -j failed — no running compositor?"

  local filtered count
  # shellcheck disable=SC2016  # $c / $argv / $cwd / $exe are jq's, not the shell's
  filtered=$(printf '%s' "$clients" | "$JQ" -c '
    [ .[]
      | select((.pid // 0) > 0)
      | select((.workspace.id // -1) >= 0)
      | select(((.class // "") | startswith("scratch-")) | not)
      | select(.mapped != false)
    ]
    | reduce .[] as $c ([]; if any(.[]; .pid == $c.pid) then . else . + [$c] end)
  ') || die "could not parse hyprctl clients -j"
  count=$(printf '%s' "$filtered" | "$JQ" 'length')

  local dir tmp jsonl i c pid class argv cwd exe n=0
  dir=$(dirname -- "$out")
  mkdir -p -- "$dir" || die "cannot create $dir"
  jsonl=$(mktemp) || die "mktemp failed"
  SAVE_TMP="$jsonl"

  i=0
  while [ "$i" -lt "$count" ]; do
    c=$(printf '%s' "$filtered" | "$JQ" -c ".[$i]")
    i=$((i + 1))
    pid=$(printf '%s' "$c" | "$JQ" -r '.pid')
    class=$(printf '%s' "$c" | "$JQ" -r '.class // ""')

    if [ ! -r "/proc/$pid/cmdline" ]; then
      skip "$class" "/proc/$pid/cmdline unreadable (process gone?)"
      continue
    fi
    # cmdline is NUL-separated; one JSON string per argument.
    argv=$(tr '\000' '\n' < "/proc/$pid/cmdline" | "$JQ" -R . | "$JQ" -s .) || argv='[]'
    if [ "$(printf '%s' "$argv" | "$JQ" 'length')" -eq 0 ]; then
      skip "$class" "empty /proc/$pid/cmdline"
      continue
    fi
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || cwd=""
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || exe=""

    # shellcheck disable=SC2016  # $c / $argv / $cwd / $exe are jq's, not the shell's
    printf '%s' "$c" | "$JQ" -c --argjson argv "$argv" --arg cwd "$cwd" --arg exe "$exe" '{
      class: (.class // ""),
      initialClass: (.initialClass // ""),
      workspace: (.workspace.id // 1),
      floating: (.floating // false),
      at: (.at // [0, 0]),
      size: (.size // [0, 0]),
      monitor: (.monitor // 0),
      pid: .pid,
      argv: $argv,
      cwd: $cwd,
      exe: $exe
    }' >> "$jsonl" || { skip "$class" "could not serialise"; continue; }
    n=$((n + 1))
  done

  tmp=$(mktemp -p "$dir" .hypr-session.XXXXXX) || die "mktemp in $dir failed"
  # shellcheck disable=SC2016  # $saved_at / $instance / $clients are jq's, not the shell's
  if ! "$JQ" -n \
    --arg saved_at "$(date -Is)" \
    --arg instance "${HYPRLAND_INSTANCE_SIGNATURE:-}" \
    --slurpfile clients "$jsonl" \
    '{ saved_at: $saved_at, hyprland_instance: $instance, clients: $clients }' > "$tmp"; then
    rm -f -- "$tmp"
    die "could not build the snapshot"
  fi
  # Atomic: the temp file is in the target directory, so the rename never
  # crosses a filesystem and a reader never sees a half-written snapshot.
  mv -f -- "$tmp" "$out" || { rm -f -- "$tmp"; die "could not write $out"; }
  echo "hypr-session: saved $n clients to $out"
}

# ── restore ──────────────────────────────────────────────────────────────────
# Strip the wrapper decoration Nix puts on a binary: /nix/store/...-kitty/bin/
# .kitty-wrapped is the real ELF behind the `kitty` shim, so its basename is the
# name to look for on PATH once the recorded store path has been collected.
exe_basename() {
  local b
  b=$(basename -- "$1")
  b=${b#.}
  b=${b%-wrapped}
  printf '%s' "$b"
}

cmd_restore() {
  local in="$DEFAULT_FILE" dry=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) [ $# -ge 2 ] || die "--from needs a FILE" 2; in="$2"; shift 2 ;;
      --dry-run) dry=1; shift ;;
      -h | --help) usage; exit 0 ;;
      *) echo "hypr-session: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
  done

  need_jq
  [ -f "$in" ] || die "no snapshot at $in (run: hypr-session save)"
  "$JQ" -e 'type == "object" and (.clients | type) == "array"' "$in" > /dev/null 2>&1 \
    || die "$in is not a hypr-session snapshot"

  if [ "$dry" -eq 0 ]; then
    command -v "$HYPRCTL" > /dev/null 2>&1 || die "hyprctl not found — is Hyprland running? (set \$HYPRCTL)"
  fi

  local count i c class pid ws floating x y w h cwd exe rules inner payload line
  local argv0 resolved base a qargv ok=0 fail=0
  local argv=()
  # `save` already keeps one entry per pid, but restore de-duplicates again: a
  # snapshot can be hand-edited or come from an older writer, and launching a
  # five-window browser five times is the expensive way to find that out.
  local -A seen_pid=()
  count=$("$JQ" '.clients | length' "$in")

  i=0
  while [ "$i" -lt "$count" ]; do
    c=$("$JQ" -c ".clients[$i]" "$in")
    i=$((i + 1))
    class=$(printf '%s' "$c" | "$JQ" -r '.class // "?"')
    pid=$(printf '%s' "$c" | "$JQ" -r '.pid // 0')
    if [ "$pid" -gt 0 ] 2>/dev/null; then
      [ -n "${seen_pid[$pid]:-}" ] && continue
      seen_pid[$pid]=1
    fi
    ws=$(printf '%s' "$c" | "$JQ" -r '.workspace // 1')
    floating=$(printf '%s' "$c" | "$JQ" -r 'if .floating then "1" else "0" end')
    x=$(printf '%s' "$c" | "$JQ" -r '.at[0] // 0')
    y=$(printf '%s' "$c" | "$JQ" -r '.at[1] // 0')
    w=$(printf '%s' "$c" | "$JQ" -r '.size[0] // 0')
    h=$(printf '%s' "$c" | "$JQ" -r '.size[1] // 0')
    cwd=$(printf '%s' "$c" | "$JQ" -r '.cwd // ""')
    exe=$(printf '%s' "$c" | "$JQ" -r '.exe // ""')

    # One JSON string per line (a JSON string never contains a literal
    # newline), decoded one at a time with `jq -j` + an x sentinel, so an
    # argument keeps its exact bytes -- command substitution would otherwise
    # eat a trailing newline.
    argv=()
    while IFS= read -r js; do
      [ -n "$js" ] || continue
      a=$(printf '%s' "$js" | "$JQ" -j '.'; printf 'x')
      argv+=("${a%x}")
    done < <(printf '%s' "$c" | "$JQ" -c '.argv[]?')
    if [ "${#argv[@]}" -eq 0 ]; then
      skip "$class" "no argv recorded"
      fail=$((fail + 1))
      continue
    fi
    argv0=${argv[0]}

    # Dry run takes argv verbatim — see the header: the gate diffs this output.
    if [ "$dry" -eq 0 ]; then
      resolved=""
      if [ -x "$argv0" ]; then
        resolved="$argv0"
      elif [[ "$argv0" != */* ]] && command -v "$argv0" > /dev/null 2>&1; then
        resolved="$argv0"
      elif [ -n "$exe" ]; then
        # argv[0] is a store path a rebuild collected, or a name that left PATH.
        base=$(exe_basename "$exe")
        if [ -n "$base" ] && command -v "$base" > /dev/null 2>&1; then
          resolved="$base"
        fi
      fi
      if [ -z "$resolved" ]; then
        skip "$class" "cannot resolve a command (argv[0]=$argv0)"
        fail=$((fail + 1))
        continue
      fi
      argv[0]="$resolved"
    fi

    qargv=""
    for a in "${argv[@]}"; do
      qargv+="${qargv:+ }$(printf '%q' "$a")"
    done
    [ -n "$cwd" ] || cwd="${HOME:-/}"

    if [ "$floating" = "1" ]; then
      rules="[workspace $ws silent; float; move $x $y; size $w $h]"
    else
      rules="[workspace $ws silent]"
    fi
    inner="cd $(printf '%q' "$cwd") && exec $qargv"
    payload="$rules sh -c $(sq "$inner")"
    line="hyprctl dispatch exec \"$payload\""

    if [ "$dry" -eq 1 ]; then
      printf '%s\n' "$line"
      continue
    fi

    if "$HYPRCTL" dispatch exec "$payload" > /dev/null 2>&1; then
      ok=$((ok + 1))
    else
      skip "$class" "hyprctl dispatch exec failed"
      fail=$((fail + 1))
    fi
    sleep 0.2
  done

  if [ "$dry" -eq 1 ]; then
    exit 0
  fi
  echo "hypr-session: relaunched $ok clients from $in ($fail skipped)" >&2
}

case "${1:-}" in
  save) shift; cmd_save "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  -h | --help) usage; exit 0 ;;
  *) echo "hypr-session: unknown argument: ${1:-}" >&2; usage >&2; exit 2 ;;
esac

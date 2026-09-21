#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# hypr-session — save the running Hyprland window set and RELAUNCH it later.
#
# Sibling of persona-layout, not a replacement:
#   persona-layout  moves windows that are ALREADY open onto their workspaces.
#   hypr-session    records each window's argv/cwd/exe and starts it again.
#
#   hypr-session save    [--to FILE]
#   hypr-session restore [--from FILE] [--dry-run] [--force]
#
# Default file: ~/.config/oligarchy/session/last.json
#
# Behaviours that are not obvious and that exist because the failure they
# prevent is SILENT:
#
#   * A save is refused only when it is almost certainly the RESTORE still in
#     flight, and the rule is INSTANCE-AWARE rather than "is it empty". The
#     failure it prevents: the save timer's `OnUnitActiveSec` clock belongs to
#     the PREVIOUS compositor — the systemd user manager outlives Hyprland — so
#     after a crash and a fast re-login the timer can fire seconds after
#     restore has DISPATCHED, while only 3 of 40 windows have MAPPED. A
#     3-client snapshot is not empty, so an emptiness test waves it through and
#     the good file is gone. The save is refused (notice on stderr, exit 0, old
#     file untouched) only when ALL THREE hold:
#       - the existing snapshot's `hyprland_instance` differs from the current
#         $HYPRLAND_INSTANCE_SIGNATURE — a DIFFERENT compositor wrote it; and
#       - the live client count is LOWER than the recorded one; and
#       - this compositor instance is younger than HYPR_SESSION_SETTLE seconds
#         (default 180 — one save interval plus margin). Age comes from
#         `hyprctl instances -j`, which is `[{instance, time}]` with `time` the
#         epoch start of each instance; when it cannot be determined the
#         instance counts as YOUNG, which keeps the refusal available rather
#         than silently disabling it. HYPR_SESSION_SETTLE=0 disables the check.
#     A save against the SAME instance that wrote the file is ALWAYS honoured,
#     including an empty one: closing every window on purpose is a state the
#     user is entitled to persist, and the old `n -eq 0` rule could never
#     record it.
#   * The previous snapshot rotates to `<name>.prev.json` only when the
#     compositor INSTANCE changes — once per crash/re-login, not once per timer
#     tick. Rotating on every save made `.prev.json` at most one save interval
#     (120s) old, so by the time a bad session was noticed both copies held it.
#   * A missing snapshot at the DEFAULT path is not an error: restore runs as
#     a login oneshot, and `exit 1` there leaves a failed unit on every first
#     boot. It prints a notice and exits 0. An explicit `--from FILE` that is
#     missing is still exit 1 — the caller named a file that should exist.
#   * Live restore is COUNT-aware, not class-aware. One `hyprctl clients -j`
#     query (taken once before the loop, filtered exactly as save filters)
#     gives a per-class count of what is already on screen, and each class then
#     launches `max(0, recorded - running)` of its recorded clients, in file
#     order. Without any such check a restore after a partially-restored
#     session doubles every window; with the old class-level boolean a PARTIAL
#     session could never be completed — one kitty opened by hand suppressed
#     all five recorded ones. `--force` skips the query and relaunches
#     everything regardless.
#
# --dry-run prints one `hyprctl dispatch exec ...` line per launch and starts
# nothing. It deliberately does NOT probe anything — no `command -v`, no `-x`
# test, no readlink, and no `hyprctl clients` query for the already-running
# check: the fixtures under home/scripts/testdata/hypr-session/ are diffed
# byte-for-byte by the `hypr-session-tests` build gate, and any probe would
# make the output depend on what happens to be installed (or open) on the
# runner. Live restore does probe, and falls back to the basename of `exe`
# when argv[0] is a /nix/store path that a rebuild has since collected.
#
# The dry-run line is `hyprctl dispatch exec <printf %q of the payload>` — a
# single %q over the WHOLE payload, never hand-written quotes around it. That
# is the only form that is shell-faithful: wrapping the payload in literal
# double quotes eats the %q backslashes, so a payload containing $, ", ` or \
# printed a command that did not match what live restore passes. Fixture
# `hostile-argv.json` exists to hold that property still.
#
# Both save and restore run a FIXED number of jq processes — two for a dry
# restore (three live, for the already-running query), three for save — four
# when a snapshot is already on disk (one jq reads its instance and count),
# five when that snapshot also has to be age-checked — not one per window and
# one per argv element. A 40-window session used to fork
# 642 jq processes and sleep 8s inside restore alone, plus 283 more on every
# 2-minute save timer tick; it is 2 and 3 now, with no sleep.
# jq emits one NUL-separated field stream (`--raw-output0`, jq >= 1.7) that a
# single bash `mapfile` slurps; save hands its per-pid argv back to one final
# jq as positional `--args`. There is no `sleep` between dispatches: `hyprctl
# dispatch exec` returns once the child is forked and the `[workspace N
# silent]` rules bind at map time, so pacing bought nothing.
#
# HYPRCTL / JQ override the binaries; both default to a PATH lookup, which is
# what the systemd user units in home/hyprland/default.nix rely on.
# HYPR_SESSION_SETTLE (seconds, default 180) is the age below which a fresh
# compositor instance is still considered to be mapping its restored windows.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

HYPRCTL="${HYPRCTL:-hyprctl}"
JQ="${JQ:-jq}"
# ${HOME:-} rather than $HOME: `set -u` would otherwise abort the whole script
# before argument parsing on a host with no HOME (a Nix build sandbox, which is
# exactly where the `hypr-session-tests` gate runs `restore --dry-run --from`).
SESSION_DIR="${HOME:-/nonexistent}/.config/oligarchy/session"
DEFAULT_FILE="$SESSION_DIR/last.json"

# Global, not `local`: the EXIT trap fires after the command's frame is gone,
# and a `local` name is unbound by then -- which under `set -u` printed an
# error on every successful save.
SAVE_TMP=""
RESTORE_TMP=""
cleanup() {
  [ -n "$SAVE_TMP" ] && rm -f -- "$SAVE_TMP"
  [ -n "$RESTORE_TMP" ] && rm -f -- "$RESTORE_TMP"
  return 0
}
trap cleanup EXIT

die() { echo "hypr-session: $1" >&2; exit "${2:-1}"; }
skip() { echo "hypr-session: skip $1: $2" >&2; }
note() { echo "hypr-session: $1" >&2; }

usage() {
  cat <<'USAGE'
usage: hypr-session save    [--to FILE]
       hypr-session restore [--from FILE] [--dry-run] [--force]

Save the current Hyprland windows (class, workspace, geometry, argv, cwd) and
relaunch them later. Scratchpads and special workspaces are skipped: exec-once
already owns those.

Options:
  --to FILE     write the snapshot here      (default ~/.config/oligarchy/session/last.json)
  --from FILE   read the snapshot from here  (default as above)
  --dry-run     print the hyprctl dispatch lines, launch nothing, exit 0
  --force       relaunch every recorded client even if clients of its class
                are already running (live restore only; --dry-run never
                queries the compositor, so --force changes nothing there)
  -h, --help    show this help

Notes:
  * A save is refused only when a DIFFERENT compositor instance wrote the
    snapshot AND the live client count is lower AND this instance is younger
    than HYPR_SESSION_SETTLE seconds — that is the restore-still-mapping case.
    The old file is kept and the command still exits 0. A save against the
    instance that wrote the file always wins, including an empty one.
  * A save rotates the previous snapshot to <name>.prev.json when the
    compositor instance changes — once per crash/re-login, not every save.
  * Live restore launches max(0, recorded - running) clients per class, so a
    partially restored session can be completed rather than doubled.
  * A missing snapshot at the DEFAULT path is a notice and exit 0, so the
    login oneshot does not fail on a first boot. A missing explicit --from
    FILE is still an error.

Environment:
  HYPRCTL       hyprctl binary (default: hyprctl on PATH)
  JQ            jq binary      (default: jq on PATH, needs >= 1.7 for
                --raw-output0)
  HYPR_SESSION_SETTLE
                seconds a new compositor instance counts as "still mapping
                restored windows" (default 180; 0 disables the save refusal)
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

# Seconds since the CURRENT compositor instance started, on stdout; non-zero
# exit when that cannot be determined. `hyprctl instances -j` answers
# [{"instance": "<sig>", "time": <epoch seconds>, ...}] — verified on this host
# as {"instance":"unknown_1789999814_...","time":1789999814}. An unknown age is
# treated by the caller as YOUNG: the conservative direction, since the other
# way a hyprctl that stopped answering would silently retire the refusal.
instance_age() {
  local sig="${HYPRLAND_INSTANCE_SIGNATURE:-}"
  [ -n "$sig" ] || return 1
  local instances t now
  instances=$("$HYPRCTL" instances -j 2>/dev/null) || return 1
  [ -n "$instances" ] || return 1
  # shellcheck disable=SC2016  # $sig is jq's binding, not the shell's
  t=$(printf '%s' "$instances" | "$JQ" -r --arg sig "$sig" '
    (if type == "array" then . else [] end)
    | map(select((.instance // "") == $sig))
    | (.[0].time // empty) | tostring
  ' 2>/dev/null) || return 1
  case "$t" in '' | *[!0-9]*) return 1 ;; esac
  now=$(date +%s 2>/dev/null) || return 1
  case "$now" in '' | *[!0-9]*) return 1 ;; esac
  printf '%s' "$((now - t))"
}

# `last.json` -> `last.prev.json`; anything else just gains a .prev suffix.
prev_path() {
  case "$1" in
    *.json) printf '%s.prev.json' "${1%.json}" ;;
    *) printf '%s.prev' "$1" ;;
  esac
}

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

  local filtered
  # shellcheck disable=SC2016  # $c is jq's, not the shell's
  filtered=$(printf '%s' "$clients" | "$JQ" -c '
    [ .[]
      | select((.pid // 0) > 0)
      | select((.workspace.id // -1) >= 0)
      | select(((.class // "") | startswith("scratch-")) | not)
      | select(.mapped != false)
    ]
    | reduce .[] as $c ([]; if any(.[]; .pid == $c.pid) then . else . + [$c] end)
  ') || die "could not parse hyprctl clients -j"

  # One jq for the whole survey: index, pid and class per surviving client, as
  # a NUL-separated stream that a single mapfile slurps. Nothing below forks jq
  # again until the snapshot is assembled.
  local survey_file
  survey_file=$(mktemp) || die "mktemp failed"
  SAVE_TMP="$survey_file"
  printf '%s' "$filtered" | "$JQ" --raw-output0 '
    to_entries[]
    | (.key | tostring),
      ((.value.pid // 0) | tostring),
      (.value.class // "" | tostring)
  ' > "$survey_file" || die "could not survey the client list"

  local -a survey=()
  mapfile -t -d '' survey < "$survey_file"

  local dir
  dir=$(dirname -- "$out")
  mkdir -p -- "$dir" || die "cannot create $dir"

  # Flat positional args for the final jq: idx, cwd, exe, argc, argv...
  local -a pos=()
  local -a argv=()
  local total=${#survey[@]} i=0 idx pid class cwd exe a n=0
  while [ "$i" -lt "$total" ]; do
    idx=${survey[i]}
    pid=${survey[i + 1]}
    class=${survey[i + 2]}
    i=$((i + 3))

    if [ ! -r "/proc/$pid/cmdline" ]; then
      skip "$class" "/proc/$pid/cmdline unreadable (process gone?)"
      continue
    fi
    # cmdline is NUL-separated. Reading it with `tr '\000' '\n'` split any
    # argument that CONTAINED a newline into two arguments -- verified with
    # `bash -c 'sleep 300; true' probe $'a\nb'`, which saved as 6 argv entries.
    # A NUL-delimited read is the only faithful way. The `|| [ -n "$a" ]` tail
    # keeps a final argument that is not NUL-terminated.
    argv=()
    a=""
    while IFS= read -r -d '' a || [ -n "$a" ]; do
      argv+=("$a")
      a=""
    done < "/proc/$pid/cmdline"
    if [ "${#argv[@]}" -eq 0 ]; then
      skip "$class" "empty /proc/$pid/cmdline"
      continue
    fi
    cwd=$(readlink "/proc/$pid/cwd" 2>/dev/null) || cwd=""
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || exe=""

    pos+=("$idx" "$cwd" "$exe" "${#argv[@]}" "${argv[@]}")
    n=$((n + 1))
  done

  # ── is this save the restore still in flight? ──────────────────────────────
  # One jq reads the instance signature and the client count of the snapshot
  # already on disk; both drive the refusal AND the rotation below.
  local cur_instance="${HYPRLAND_INSTANCE_SIGNATURE:-}"
  local old_n=0 old_instance="" have_old=0 instance_changed=0
  if [ -f "$out" ]; then
    have_old=1
    local -a old_meta=()
    mapfile -t -d '' old_meta < <("$JQ" --raw-output0 '
      ((.hyprland_instance // "") | tostring),
      (((.clients // []) | length) | tostring)
    ' "$out" 2>/dev/null)
    if [ "${#old_meta[@]}" -ge 2 ]; then
      old_instance=${old_meta[0]}
      old_n=${old_meta[1]}
      case "$old_n" in '' | *[!0-9]*) old_n=0 ;; esac
    fi
    # An unreadable/legacy snapshot leaves old_instance empty, which counts as
    # "a different instance wrote it" — so it still gets rotated before it is
    # replaced, while old_n stays 0 and can therefore never trigger a refusal.
    [ "$old_instance" != "$cur_instance" ] && instance_changed=1
  fi

  # The refusal is INSTANCE-AWARE; see the header for why "is the new snapshot
  # empty" was both too weak and too strong. All three conditions must hold:
  # a DIFFERENT compositor wrote the file we would replace, we have FEWER
  # clients than it records, and this compositor is young enough that a restore
  # could still be mapping windows into it. A save against the instance that
  # wrote the file is always honoured, empty included.
  if [ "$instance_changed" -eq 1 ] && [ "$n" -lt "$old_n" ]; then
    local settle="${HYPR_SESSION_SETTLE:-180}"
    case "$settle" in '' | *[!0-9]*) settle=180 ;; esac
    local age=""
    age=$(instance_age) || age=""
    if [ "$settle" -gt 0 ] && { [ -z "$age" ] || [ "$age" -lt "$settle" ]; }; then
      note "refusing to overwrite $out ($old_n clients, instance ${old_instance:-unknown}) with $n from an instance only ${age:-?}s old; a restore is probably still mapping windows. Keeping the old snapshot (HYPR_SESSION_SETTLE=0 disables this)."
      exit 0
    fi
  fi

  local tmp
  tmp=$(mktemp -p "$dir" .hypr-session.XXXXXX) || die "mktemp in $dir failed"
  # One jq builds the whole snapshot. $ARGS.positional is the flat
  # idx/cwd/exe/argc/argv... stream walked back into records; $clients is the
  # already-filtered client list the indexes point into.
  #
  # The `--` before the positionals is load-bearing, not tidiness: `--args`
  # does NOT stop jq's own option parsing, and argv is full of things that
  # look like options. `jq -n --args F x -c y` silently drops the `-c` (and
  # switches jq to compact output); `--tab=3` -- a real pavucontrol argument
  # -- is a fatal "Unknown option". Both verified on jq 1.8.1.
  # shellcheck disable=SC2016  # $clients / $saved_at / $instance are jq's
  if ! "$JQ" -n \
    --argjson clients "$filtered" \
    --arg saved_at "$(date -Is)" \
    --arg instance "${HYPRLAND_INSTANCE_SIGNATURE:-}" \
    --args '
      def records($p):
        if ($p | length) == 0 then []
        else
          ($p[0] | tonumber) as $idx
          | $p[1] as $cwd
          | $p[2] as $exe
          | ($p[3] | tonumber) as $argc
          | $p[4:4 + $argc] as $argv
          | [ $clients[$idx]
              | {
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
                }
            ]
            + records($p[4 + $argc:])
        end;
      {
        saved_at: $saved_at,
        hyprland_instance: $instance,
        clients: records($ARGS.positional)
      }
    ' -- ${pos[@]+"${pos[@]}"} > "$tmp"; then
    rm -f -- "$tmp"
    die "could not build the snapshot"
  fi

  # Rotate first, replace second: `cp` leaves the live file in place, so the
  # `mv` below is still the only thing that ever changes $out, and a reader
  # never sees a half-written snapshot (the temp is in the target directory,
  # so the rename never crosses a filesystem).
  #
  # ONLY on an instance change — one .prev.json per compositor instance, i.e.
  # per crash/re-login. Rotating on every tick capped the recovery window at
  # one save interval (120s), which is shorter than it takes to notice that a
  # session came back wrong. The first save of a new instance writes $out with
  # the new signature, so every later save in that instance sees
  # instance_changed=0 and leaves the rotated copy alone.
  if [ "$have_old" -eq 1 ] && [ "$instance_changed" -eq 1 ]; then
    local prev
    prev=$(prev_path "$out")
    cp -f -- "$out" "$prev" 2>/dev/null || note "could not rotate $out to $prev"
  fi
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
  local in="$DEFAULT_FILE" dry=0 force=0 explicit=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --from) [ $# -ge 2 ] || die "--from needs a FILE" 2; in="$2"; explicit=1; shift 2 ;;
      --dry-run) dry=1; shift ;;
      --force) force=1; shift ;;
      -h | --help) usage; exit 0 ;;
      *) echo "hypr-session: unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
  done

  need_jq
  if [ ! -f "$in" ]; then
    # A caller that NAMED a file expects it to exist; the default path on a
    # first boot does not. restore is a login oneshot, so exit 1 there is a
    # failed unit for a condition that is entirely normal.
    [ "$explicit" -eq 1 ] && die "no snapshot at $in (run: hypr-session save)"
    note "no snapshot at $in yet — nothing to restore"
    exit 0
  fi
  "$JQ" -e 'type == "object" and (.clients | type) == "array"' "$in" > /dev/null 2>&1 \
    || die "$in is not a hypr-session snapshot"

  if [ "$dry" -eq 0 ]; then
    command -v "$HYPRCTL" > /dev/null 2>&1 || die "hyprctl not found — is Hyprland running? (set \$HYPRCTL)"
  fi

  # How MANY of each class are already on screen. Queried ONCE, before the
  # loop, and never in --dry-run: the gate diffs dry-run output byte-for-byte,
  # so it must not depend on what happens to be open on the runner.
  #
  # A count, not a boolean. A boolean made a partial restore unrecoverable —
  # one kitty opened by hand suppressed all five recorded ones. The filter is
  # save's, verbatim (pid, non-special workspace, non-scratch, mapped, then one
  # entry per pid), so "recorded" and "running" are counting the same thing on
  # both sides; a different filter here would silently bias every deficit.
  local -A running=()
  if [ "$dry" -eq 0 ] && [ "$force" -eq 0 ]; then
    local live k
    live=$("$HYPRCTL" clients -j 2>/dev/null) || live=""
    if [ -n "$live" ]; then
      # The "c:" prefix is not decoration: an unprefixed associative-array
      # subscript of `@` or `*` is the expand-every-element form, so a window
      # whose class happened to be one of those would read as "everything is
      # already running".
      # shellcheck disable=SC2016  # $c is jq's, not the shell's
      while IFS= read -r -d '' k; do
        [ -n "$k" ] && running["c:$k"]=$(( ${running["c:$k"]:-0} + 1 ))
      done < <(printf '%s' "$live" | "$JQ" --raw-output0 '
        [ .[]?
          | select((.pid // 0) > 0)
          | select((.workspace.id // -1) >= 0)
          | select(((.class // "") | startswith("scratch-")) | not)
          | select(.mapped != false)
        ]
        | reduce .[] as $c ([]; if any(.[]; .pid == $c.pid) then . else . + [$c] end)
        | .[] | (.class // "" | tostring)
      ' 2>/dev/null)
    fi
  fi

  # One jq for the whole snapshot: eleven fixed fields then argc argv elements
  # per client, NUL-separated, slurped by a single mapfile. This used to be
  # ~12 jq forks per client plus one per argv element.
  local recfile
  recfile=$(mktemp) || die "mktemp failed"
  RESTORE_TMP="$recfile"
  # shellcheck disable=SC2016  # $argv / $at / $size are jq's, not the shell's
  "$JQ" --raw-output0 '
    .clients[]?
    | (.argv | if type == "array" then . else [] end) as $argv
    | (.at | if type == "array" then . else [] end) as $at
    | (.size | if type == "array" then . else [] end) as $size
    | (.class // "?" | tostring),
      ((.pid // 0) | tostring),
      ((.workspace // 1) | tostring),
      (if .floating then "1" else "0" end),
      (($at[0] // 0) | tostring),
      (($at[1] // 0) | tostring),
      (($size[0] // 0) | tostring),
      (($size[1] // 0) | tostring),
      (.cwd // "" | tostring),
      (.exe // "" | tostring),
      (($argv | length) | tostring),
      ($argv[] | tostring)
  ' "$in" > "$recfile" || die "could not read the snapshot at $in"

  local -a rec=()
  mapfile -t -d '' rec < "$recfile"

  local class pid ws floating x y w h cwd exe argc rules inner payload
  local argv0 resolved base a qargv ok=0 fail=0 dup=0
  local -a argv=()
  # `save` already keeps one entry per pid, but restore de-duplicates again: a
  # snapshot can be hand-edited or come from an older writer, and launching a
  # five-window browser five times is the expensive way to find that out.
  local -A seen_pid=()
  # One "skip <class>: N already running" line per class, not per window.
  local -A skip_logged=()
  local total=${#rec[@]} i=0

  while [ "$i" -lt "$total" ]; do
    class=${rec[i]}
    pid=${rec[i + 1]}
    ws=${rec[i + 2]}
    floating=${rec[i + 3]}
    x=${rec[i + 4]}
    y=${rec[i + 5]}
    w=${rec[i + 6]}
    h=${rec[i + 7]}
    cwd=${rec[i + 8]}
    exe=${rec[i + 9]}
    argc=${rec[i + 10]}
    case "$argc" in ''|*[!0-9]*) die "$in is malformed (bad argv count near field $((i + 10)))" ;; esac
    # Quoted: an unquoted slice would word-split and glob every argument.
    argv=("${rec[@]:i + 11:argc}")
    i=$((i + 11 + argc))

    if [ "$pid" -gt 0 ] 2>/dev/null; then
      [ -n "${seen_pid[$pid]:-}" ] && continue
      seen_pid[$pid]=1
    fi

    # A second restore into a half-restored session doubled every window; a
    # class-level boolean fixed that and broke completing a PARTIAL one. Per
    # class the first `running` recorded clients are consumed and the rest
    # launch, so exactly max(0, recorded - running) of each class starts, in
    # file order: 5 kitty recorded with 1 open by hand launches 4.
    if [ -n "$class" ] && [ "${running["c:$class"]:-0}" -gt 0 ]; then
      if [ -z "${skip_logged["c:$class"]:-}" ]; then
        skip "$class" "${running["c:$class"]} already running"
        skip_logged["c:$class"]=1
      fi
      running["c:$class"]=$(( ${running["c:$class"]} - 1 ))
      dup=$((dup + 1))
      continue
    fi

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

    if [ "$dry" -eq 1 ]; then
      # ONE %q over the whole payload. Wrapping it in hand-written double
      # quotes instead printed a line the shell would not reproduce: the outer
      # quotes swallow the %q backslashes, so $, ", ` and \ in argv came out
      # as a different command than live restore passes.
      printf 'hyprctl dispatch exec %q\n' "$payload"
      continue
    fi

    # No pacing sleep: `hyprctl dispatch exec` returns once the child is
    # forked, and `[workspace N silent]` binds when the window maps, not when
    # the dispatch is issued. The old `sleep 0.2` cost 8s on a 40-window
    # session and guaranteed nothing.
    if "$HYPRCTL" dispatch exec "$payload" > /dev/null 2>&1; then
      ok=$((ok + 1))
    else
      skip "$class" "hyprctl dispatch exec failed"
      fail=$((fail + 1))
    fi
  done

  if [ "$dry" -eq 1 ]; then
    exit 0
  fi
  echo "hypr-session: relaunched $ok clients from $in ($fail skipped, $dup already running)" >&2
}

case "${1:-}" in
  save) shift; cmd_save "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  -h | --help) usage; exit 0 ;;
  *) echo "hypr-session: unknown argument: ${1:-}" >&2; usage >&2; exit 2 ;;
esac

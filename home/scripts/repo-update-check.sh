#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# repo-update-check — quietly notices when the tracked remote branch has
# commits this checkout doesn't, without nagging.
#
#   repo-update-check           # fetch + notify once per new remote SHA
#                                # (run on a timer, see home/scripts/default.nix)
#   repo-update-check --quiet   # report current state as waybar JSON, no
#                                # network call, no notification — cheap
#                                # enough to poll every few minutes
#   repo-update-check --log     # print the pending commits (for on-click)
#
# "Non-annoying": a fetch happens only on the timer's own schedule, never on
# every waybar poll; a notification fires at most once per distinct remote
# SHA (tracked in $STATE_FILE), not once per timer tick; low urgency, short
# timeout, no repeated pop-ups for an update you've already been told about.
#
# Does NOT assume the checkout is on a branch named "main" with an upstream
# configured — checked live against a real deployed checkout (/etc/nixos)
# that's on "master" with no tracking branch set at all, which a hardcoded
# "origin/main" comparison would have silently done nothing for. Prefers the
# current branch's actual upstream (@{u}); falls back to whichever of
# origin/main or origin/master exists if there is none.
#
# --quiet always emits valid JSON on every exit path, even "can't tell yet"
# ones (e.g. no remote-tracking ref cached before the first real fetch) —
# checked live: without this, waybar's return-type=json module gets no
# output at all on that path, not just an empty one.
# ─────────────────────────────────────────────────────────────────────────────
set -uo pipefail

FLAKE_DIR="${OLIGARCHY_FLAKE_DIR:-/etc/nixos}"
STATE_FILE="$HOME/.cache/oligarchy/repo-update-notified-sha"
mode="${1:-}"

mkdir -p "$(dirname "$STATE_FILE")"

bail() {
  [ "$mode" = "--quiet" ] && printf '{"text":"","tooltip":""}\n'
  exit 0
}

[ -d "$FLAKE_DIR/.git" ] || bail

if [ "$mode" != "--quiet" ]; then
  git -C "$FLAKE_DIR" fetch --quiet 2>/dev/null || bail
fi

remote_ref="$(git -C "$FLAKE_DIR" rev-parse --abbrev-ref '@{u}' 2>/dev/null || true)"
if [ -z "$remote_ref" ]; then
  for candidate in origin/main origin/master; do
    if git -C "$FLAKE_DIR" rev-parse --verify -q "$candidate" >/dev/null 2>&1; then
      remote_ref="$candidate"
      break
    fi
  done
fi
[ -z "$remote_ref" ] && bail

local_sha="$(git -C "$FLAKE_DIR" rev-parse HEAD 2>/dev/null || true)"
remote_sha="$(git -C "$FLAKE_DIR" rev-parse "$remote_ref" 2>/dev/null || true)"
if [ -z "$local_sha" ] || [ -z "$remote_sha" ]; then
  bail
fi

count="$(git -C "$FLAKE_DIR" rev-list --count "$local_sha..$remote_sha" 2>/dev/null || echo 0)"

case "$mode" in
  --quiet)
    if [ "${count:-0}" -gt 0 ] 2>/dev/null; then
      printf '{"text":"⇡ %s","tooltip":"%s new commit(s) on %s — click to view","class":"pending"}\n' \
        "$count" "$count" "$remote_ref"
    else
      printf '{"text":"","tooltip":""}\n'
    fi
    ;;
  --log)
    git -C "$FLAKE_DIR" log --oneline "$local_sha..$remote_sha" 2>/dev/null
    ;;
  *)
    if [ "${count:-0}" -gt 0 ] 2>/dev/null; then
      already_notified="$(cat "$STATE_FILE" 2>/dev/null || true)"
      if [ "$remote_sha" != "$already_notified" ]; then
        summary="$(git -C "$FLAKE_DIR" log --oneline "$local_sha..$remote_sha" 2>/dev/null | head -5)"
        notify-send -u low -t 8000 "⌁ Oligarchy repo updated" \
          "$count new commit(s) on $remote_ref:
$summary" 2>/dev/null || true
        echo "$remote_sha" > "$STATE_FILE"
      fi
    fi
    ;;
esac

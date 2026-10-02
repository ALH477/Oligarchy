#!/usr/bin/env bash
# modules/oligarchy-plugins/potestas-cert/potestas/regen.sh -- re-emit
# potestas.gen.c from an Exsecutor checkout and compare it with the committed
# copy (or overwrite it, --write).
#   EXSECUTOR=/path/to/exsecutor potestas/regen.sh [--write]
#   EXSC=/path/to/exsc EXSECUTOR=... potestas/regen.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
: "${EXSECUTOR:?set EXSECUTOR to an exsecutor checkout}"
exsc="${EXSC:-$EXSECUTOR/build/exsc}"
[ -x "$exsc" ] || { echo "regen: $exsc missing -- 'make all' in \$EXSECUTOR, or set EXSC" >&2; exit 2; }
src="$EXSECUTOR/examples/potestas/potestas.exsc"
[ -f "$src" ] || { echo "regen: $src absent (not upstream at that commit)" >&2; exit 3; }
out="$(mktemp)"; trap 'rm -f "$out"' EXIT
"$exsc" aedifica --hospes x86_64-linux --emitte c "$src" -o "$out" >/dev/null 2>&1
echo "exsecutor: $(git -C "$EXSECUTOR" rev-parse HEAD 2>/dev/null || echo '?')"
echo "sha256:    $(sha256sum "$out" | cut -d' ' -f1)  ($(wc -c <"$out") bytes)"
if [ "${1:-}" = "--write" ]; then
  cp "$out" "$here/potestas.gen.c"; echo "wrote potestas.gen.c -- update PROVENANCE.md"
elif cmp -s "$out" "$here/potestas.gen.c"; then
  echo "potestas.gen.c: byte-identical"
else
  echo "potestas.gen.c: DIFFERS from what this exsc emits" >&2; exit 1
fi

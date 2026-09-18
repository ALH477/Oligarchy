#!/usr/bin/env bash
# Early-boot helper. No Python. Never fails the boot.
# Picks one pool verse and paints it onto Plymouth, /dev/console, and /run.
set +e
set -u

umask 022

sanitize() {
  # Drop C0/C1 controls except TAB. Collapse newlines in plymouth/issue text.
  printf '%s' "$1" | tr -d '\000-\010\013\014\016-\037\177'
}

POOL="${SCROLLMAPPER_BOOT_POOL:-}"
if [ -z "${POOL}" ] || [ ! -r "${POOL}" ]; then
  echo "scrollmapper-boot-dialogue: pool missing" >&2
  exit 0
fi

n=$(wc -l < "${POOL}" 2>/dev/null | tr -d ' [:alpha:]')
case "${n}" in
  ''|*[!0-9]*) exit 0 ;;
esac
[ "${n}" -gt 0 ] || exit 0

raw=
if [ -r /dev/urandom ]; then
  raw=$(od -An -N4 -tu4 /dev/urandom 2>/dev/null | tr -d ' \n\t')
fi
case "${raw}" in
  ''|*[!0-9]*) raw=1 ;;
esac
idx=$(( raw % n + 1 ))

line=$(sed -n "${idx}p" "${POOL}" 2>/dev/null)
[ -n "${line}" ] || exit 0

book=$(sanitize "${line%%	*}")
rest="${line#*	}"
chapter=$(sanitize "${rest%%	*}")
rest="${rest#*	}"
verse=$(sanitize "${rest%%	*}")
text=$(sanitize "${rest#*	}")

ref="${book} ${chapter}:${verse}"
plain="${ref}
${text}"

plymouth_text="${ref} — ${text}"
if [ "${#plymouth_text}" -gt 140 ]; then
  plymouth_text="${plymouth_text:0:137}..."
fi

# ASCII console block — early getty fonts often lack box drawing.
console_block="-- scrollmapper --
${ref}
${text}
------------------"

if ! mkdir -p /run/scrollmapper 2>/dev/null; then
  exit 0
fi
chmod 0755 /run/scrollmapper 2>/dev/null

printf '%s\n' "${plain}" > /run/scrollmapper/verse
printf '%s\n' "${ref}" > /run/scrollmapper/ref
printf '%s\n' "${text}" > /run/scrollmapper/text
printf '%s\n' "${plymouth_text}" > /run/scrollmapper/plymouth
chmod 0644 /run/scrollmapper/verse /run/scrollmapper/ref /run/scrollmapper/text /run/scrollmapper/plymouth 2>/dev/null

if [ "${SCROLLMAPPER_BOOT_PLYMOUTH:-1}" != "0" ]; then
  if command -v plymouth >/dev/null 2>&1; then
    plymouth display-message --text="${plymouth_text}" >/dev/null 2>&1
  fi
fi

if [ "${SCROLLMAPPER_BOOT_CONSOLE:-1}" != "0" ] && [ -w /dev/console ]; then
  printf '\n%s\n\n' "${console_block}" > /dev/console 2>/dev/null
fi

exit 0

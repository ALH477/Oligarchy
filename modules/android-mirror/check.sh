#!/usr/bin/env bash
# Asserts the installed phone-mirror wrapper is USB-game-shaped.
# Run via: nix build .#phone-mirror && bash modules/android-mirror/check.sh result
set -euo pipefail
root=${1:-./result}
bin=$root/bin/phone-mirror
scrcpy=$root/bin/scrcpy

fail() { echo "FAIL: $*" >&2; exit 1; }

[[ -x $bin ]] || fail "missing $bin"
[[ -x $scrcpy ]] || fail "missing vanilla scrcpy at $scrcpy"
[[ ! -e $root/bin/fastboot ]] || fail "android-tools leaked onto PATH (fastboot present)"
[[ ! -e $root/bin/adb ]] || fail "android-tools leaked onto PATH (adb present; it belongs in runtimeInputs only)"

help=$("$bin" --help)
echo "$help" | grep -q "USB" || fail "help does not say USB"
echo "$help" | grep -q "minecraft" || fail "help does not mention minecraft"

src=$(cat "$bin")

echo "$src" | grep -q -- '--select-usb' || fail "missing --select-usb"
echo "$src" | grep -q -- '--video-buffer=0' || fail "missing --video-buffer=0"
echo "$src" | grep -q -- '--keyboard=uhid' || fail "missing --keyboard=uhid"
echo "$src" | grep -q -- '--mouse=uhid' || fail "missing --mouse=uhid"
echo "$src" | grep -q -- '--gamepad=uhid' || fail "missing --gamepad=uhid"
echo "$src" | grep -q -- 'com.mojang.minecraftpe' || fail "missing Bedrock package id"
echo "$src" | grep -q 'DRI_PRIME' && fail "DRI_PRIME must not appear"
echo "$src" | grep -- '--turn-screen-off' && fail "--turn-screen-off must not appear in the wrapper"
# --tcpip may appear only as a "don't do this" note, never as an argv flag.
if echo "$src" | grep -- '--tcpip' | grep -v 'scrcpy --tcpip' >/dev/null; then
  fail "--tcpip must not appear as a wrapper flag"
fi
echo "ok"

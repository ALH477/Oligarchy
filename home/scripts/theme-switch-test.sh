#!/usr/bin/env bash
set -euo pipefail
# Task 1: prove today's prefix matcher picks Night Owl when the user chose Night.
choice="Night"
options=("Night Owl" "Night")
ids=(beta alpha)
got=""
for i in "${!options[@]}"; do
  if [[ "${options[$i]}" == "$choice"* ]]; then got="${ids[$i]}"; break; fi
done
if [[ "$got" == "alpha" ]]; then
  echo "FAIL: expected prefix-bug (got alpha); test harness wrong"
  exit 1
fi
echo "confirmed prefix bug: choosing 'Night' matched '$got' (want alpha)"

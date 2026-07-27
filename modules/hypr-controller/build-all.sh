#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2025-2026, Asher LeRoy
#
# nixos-rebuild + HyprController APK, tuned so neither half can wedge this
# laptop. Run from anywhere:  modules/hypr-controller/build-all.sh
#
# WHY THE CAPS ARE ON THE COMMAND LINE, not just in configuration.nix:
# configuration.nix sets nix.settings.max-jobs/cores, but that is only true of
# the system you are about to BUILD — the daemon running this build still has
# whatever the current generation gave it (check: `nix config show | grep -E
# '^(max-jobs|cores)'`). It read max-jobs=16 / cores=0 here, which is how a
# full closure build OOM'd the box and took the display with it. So the first
# rebuild must carry its own caps; later ones inherit them.
#
# 16 CPUs, but isolcpus=0,1 hands two to the DSP guest -> 14 schedulable.
# Nix: 3 jobs x 4 cores = 12 threads peak, 2 CPUs of headroom (the product is
# the number that matters; raising max-jobs costs more than cores because each
# job also holds memory). Gradle gets 4 workers in a single JVM.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ANDROID_DIR="$REPO/modules/hypr-controller/android"

NIX_MAX_JOBS=${NIX_MAX_JOBS:-3}
NIX_CORES=${NIX_CORES:-4}
GRADLE_WORKERS=${GRADLE_WORKERS:-4}

echo "==> [1/2] nixos-rebuild switch (max-jobs=$NIX_MAX_JOBS cores=$NIX_CORES)"
sudo nixos-rebuild switch \
  --flake "$REPO#nixos" \
  --max-jobs "$NIX_MAX_JOBS" \
  --cores "$NIX_CORES"

# Only meaningful after the switch above, which is what activates zramSwap.
if [ -z "$(swapon --show --noheadings 2>/dev/null)" ]; then
  echo "!! no swap active — zram did not come up; the Gradle half is less protected" >&2
fi

echo "==> [2/2] HyprController APK (workers=$GRADLE_WORKERS)"

# The SDK lives in the nix store and is READ-ONLY, so point Gradle's writable
# state (caches, installed-package metadata) somewhere else or AGP fails trying
# to write next to the platform.
SDK_ROOT="$(dirname "$(dirname "$(dirname "$(dirname "$(readlink -f "$(command -v sdkmanager)")")")")")"
export ANDROID_SDK_ROOT="$SDK_ROOT"
export ANDROID_HOME="$SDK_ROOT"
export ANDROID_USER_HOME="${XDG_DATA_HOME:-$HOME/.local/share}/android"
mkdir -p "$ANDROID_USER_HOME"
echo "    SDK: $ANDROID_SDK_ROOT"

# Hard memory ceiling. Unlike the nix half — whose builders run under
# nix-daemon, out of reach of a --user scope — Gradle is our own process, so
# MemoryMax genuinely binds it. CPUWeight keeps the desktop ahead of it.
#
# --no-daemon + in-process Kotlin: one JVM instead of three (Gradle daemon +
# Kotlin daemon + build). Slower on repeat builds, much kinder on RAM.
# nix shell provides gradle: it is not installed, and android/gradle/wrapper/
# has no gradle-wrapper.jar (Android Studio generates that binary; nothing here
# fakes it).
exec systemd-run --user --scope --quiet \
  -p MemoryMax=8G -p MemorySwapMax=4G -p CPUWeight=50 \
  nix shell nixpkgs#gradle --command \
    nice -n 10 gradle -p "$ANDROID_DIR" assembleDebug \
      --no-daemon \
      --max-workers="$GRADLE_WORKERS" \
      -Dorg.gradle.jvmargs=-Xmx3g \
      -Dkotlin.compiler.execution.strategy=in-process

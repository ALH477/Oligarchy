#!/usr/bin/env bash
# SPDX-License-Identifier: BSD-3-Clause
# Copyright (c) 2025-2026, Asher LeRoy
#
# rebuild — NixOS rebuild with resource caps and optional input updates.
# Defaults to pinned (locked) inputs. Use --update to bump inputs first.
# Run from anywhere: rebuild, rebuild --test, rebuild --update nixpkgs
set -euo pipefail

# ── Flake discovery ──────────────────────────────────────────────────────────
FLAKE_DIR="${OLIGARCHY_FLAKE_DIR:-}"
if [ -z "$FLAKE_DIR" ]; then
  FLAKE_DIR="$(git rev-parse --show-toplevel 2>/dev/null)" || true
  if [ -z "$FLAKE_DIR" ] || [ ! -f "$FLAKE_DIR/flake.nix" ]; then
    d="$PWD"
    while [ "$d" != "/" ]; do
      if [ -f "$d/flake.nix" ]; then FLAKE_DIR="$d"; break; fi
      d="$(dirname "$d")"
    done
  fi
fi
HOST="${OLIGARCHY_HOST:-nixos}"

# Resource caps match configuration.nix nix.settings (3 jobs × 4 cores = 12
# threads, 2 CPU headroom for the DSP guest on isolcpus=0,1).
NIX_MAX_JOBS="${NIX_MAX_JOBS:-3}"
NIX_CORES="${NIX_CORES:-4}"

# ── Defaults ─────────────────────────────────────────────────────────────────
mode="switch"
update_inputs=()
max_jobs="$NIX_MAX_JOBS"
cores="$NIX_CORES"

usage() {
  cat <<'EOF'
usage: rebuild [OPTIONS]

NixOS rebuild with resource caps. Defaults to pinned flake inputs.

Options:
  --update [INPUT...]  Update flake inputs before building
                       (no args = all inputs; name specific inputs to bump selectively)
  --test               nixos-rebuild test instead of switch
  --dry-run            nixos-rebuild dry-build (build without activating)
  --max-jobs N         Override max-jobs (default: 3)
  --cores N            Override cores per job (default: 4)
  --host HOST          Override hostname attr (default: nixos)
  -h, --help           Show this help

Environment:
  OLIGARCHY_FLAKE_DIR  Flake checkout directory (default: git root or CWD)
  OLIGARCHY_HOST       Hostname attribute (default: nixos)
  NIX_MAX_JOBS         Default max-jobs (default: 3)
  NIX_CORES            Default cores (default: 4)

Examples:
  rebuild                    # switch with pinned inputs
  rebuild --test             # test with pinned inputs
  rebuild --update           # update ALL inputs, then switch
  rebuild --update nixpkgs  # update only nixpkgs, then switch
  rebuild --update nixpkgs home-manager --test
  rebuild --dry-run          # dry-build (no activation)
  rebuild --max-jobs 4 --cores 6
EOF
}

# ── Parse arguments ─────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
  case "$1" in
    --update)
      shift
      update_inputs=()
      if [ $# -gt 0 ] && [[ "$1" != --* ]]; then
        while [ $# -gt 0 ] && [[ "$1" != --* ]]; do
          update_inputs+=("$1")
          shift
        done
      else
        update_inputs=("--all")
      fi
      ;;
    --test)     mode="test";       shift ;;
    --dry-run)  mode="dry-build";  shift ;;
    --max-jobs) max_jobs="$2"; shift 2 ;;
    --cores)    cores="$2";    shift 2 ;;
    --host)     HOST="$2";     shift 2 ;;
    -h|--help)  usage; exit 0 ;;
    *)          echo "unknown flag: $1" >&2; usage; exit 2 ;;
  esac
done

# ── Validate ─────────────────────────────────────────────────────────────────
if [ -z "$FLAKE_DIR" ] || [ ! -f "$FLAKE_DIR/flake.nix" ]; then
  echo "!! no flake found — set OLIGARCHY_FLAKE_DIR or run from the repo" >&2
  exit 1
fi

# ── Update phase (optional) ──────────────────────────────────────────────────
if [ "${#update_inputs[@]}" -gt 0 ]; then
  if [ "${update_inputs[0]}" = "--all" ]; then
    echo "==> updating ALL flake inputs"
    (cd "$FLAKE_DIR" && nix flake update)
  else
    echo "==> updating flake inputs: ${update_inputs[*]}"
    (cd "$FLAKE_DIR" && nix flake update "${update_inputs[@]}")
  fi
  if [ $? -ne 0 ]; then
    echo "!! flake update failed" >&2
    exit 1
  fi
fi

# ── Build + activate ──────────────────────────────────────────────────────────
echo "==> nixos-rebuild $mode --flake $FLAKE_DIR#$HOST (max-jobs=$max_jobs cores=$cores)"
sudo nixos-rebuild "$mode" \
  --flake "$FLAKE_DIR#$HOST" \
  --max-jobs "$max_jobs" \
  --cores "$cores"
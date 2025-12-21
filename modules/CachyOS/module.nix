# modules/CachyOS/module.nix
# Copyright (c) 2025 DeMoD LLC
# SPDX-License-Identifier: BSD-3-Clause
#
# NixOS module for selecting a CachyOS kernel variant.
#
# Recommended for gaming + creative work: variant = "bore" (BORE scheduler)
#   - Top choice in 2025 benchmarks for low latency, smooth FPS, and responsive desktop.
#   - Excellent for games, Blender, video editing, etc.
# Optional: lto = true for ThinLTO builds (small perf gain, usually cached).

{ cachyos-kernels, lib, config, pkgs, ... }:

let
  cfg = config.boot.cachyosKernel;

  variantMap = {
    latest    = "latest";     # Latest kernel with CachyOS default tunings
    lts       = "lts";        # LTS kernel
    bmq       = "bmq";        # BMQ scheduler
    bore      = "bore";       # BORE scheduler – best for gaming/interactive (recommended)
    deckify   = "deckify";    # Steam Deck optimized
    eevdf     = "eevdf";      # Tuned EEVDF
    hardened  = "hardened";   # Security-hardened
    "rt-bore" = "rt-bore";    # Real-time BORE
    server    = "server";     # Server/throughput optimized
  };

  variantSuffix = variantMap.${cfg.variant};
  ltoSuffix = if cfg.lto then "-lto" else "";
  fullSuffix = variantSuffix + ltoSuffix;

  # Upstream uses hyphens in attribute names (e.g., linuxPackages-cachyos-bore-lto)
  kernelAttr = "linuxPackages-cachyos-${fullSuffix}";
in
{
  options.boot.cachyosKernel = {
    enable = lib.mkEnableOption "CachyOS performance-optimized kernel";

    variant = lib.mkOption {
      type = lib.types.enum (builtins.attrNames variantMap);
      default = "bore";
      description = ''
        CachyOS kernel variant.
        "bore" is the top recommendation for gaming and creative workloads.
      '';
    };

    lto = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable ThinLTO-optimized build (small performance boost, usually cached).";
    };
  };

  config = lib.mkIf cfg.enable {
    # Use the pinned overlay for reliable binary cache hits
    nixpkgs.overlays = [ cachyos-kernels.overlays.pinned ];

    # Select the kernel from the cachyosKernels attrset
    boot.kernelPackages = pkgs.cachyosKernels.${kernelAttr};
  };
}

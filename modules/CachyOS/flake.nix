# modules/CachyOS/flake.nix
# Copyright (c) 2025 DeMoD LLC
# SPDX-License-Identifier: BSD-3-Clause
#
# Standalone NixOS flake providing a configurable module for CachyOS kernels.
#
# Based on the actively maintained upstream: https://github.com/xddxdd/nix-cachyos-kernel
# - Last checked: December 20, 2025 (active, latest commit today)
# - Highly recommended for performance (especially gaming/creative workloads)
# - Uses the /release branch for reliable binary cache hits

{
  description = "NixOS module for configurable CachyOS kernels (gaming/desktop optimized)";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    # Use the release branch for pre-built kernels with binary cache support
    cachyos-kernels = {
      url = "github:xddxdd/nix-cachyos-kernel/release";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, cachyos-kernels }: {

    nixosModules.cachyosKernel = import ./module.nix {
      inherit cachyos-kernels;
    };

    nixosModules.default = self.nixosModules.cachyosKernel;

  };
}

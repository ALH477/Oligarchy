{ config, pkgs, lib, ... }:

# ============================================================================
# Optimized Kernel Module for Framework 16 AMD
# ============================================================================
#
# Default: Zen kernel (pre-built, immediate availability)
#   - Low-latency scheduler optimizations
#   - Gaming and audio production optimized
#   - MuQSS scheduler
#
# Alternative: CachyOS BORE (requires building from source)
#   - Set kernelChoice = "cachyos-bore"
#   - Update the sha256 hashes below
#   - First build will take 30-60 minutes
#
# ============================================================================

let
  # ─────────────────────────────────────────────────────────────────────────
  # KERNEL SELECTION
  # ─────────────────────────────────────────────────────────────────────────
  # Variant is now a declarative option: custom.kernel.variant
  # ("zen" | "xanmod" | "latest" | "cachyos-bore"). Set it in configuration.nix
  # or via the control center (writes ./oligarchy-local.nix).
  cfg = config.custom.kernel;

  # ─────────────────────────────────────────────────────────────────────────
  # CachyOS BORE Configuration (only if kernelChoice = "cachyos-bore")
  # ─────────────────────────────────────────────────────────────────────────
  # To get correct hashes:
  #   1. Set sha256 to lib.fakeHash
  #   2. Run: nix build .#nixosConfigurations.nixos.config.system.build.toplevel 2>&1 | grep 'got:'
  #   3. Copy the correct hash
  
  cachyosVersion = "6.12.10";
  cachyosDir = "6.12";
  
  # Kernel source
  cachyos-src = pkgs.fetchurl {
    url = "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${cachyosVersion}.tar.xz";
    sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";  # Replace with actual hash
  };
  
  # CachyOS defconfig
  cachyos-config = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/CachyOS/linux-cachyos/master/linux-cachyos-bore/config";
    sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";  # Replace with actual hash
  };
  
  # CachyOS patches
  cachyos-patches = [
    {
      name = "cachyos-base-all";
      patch = pkgs.fetchpatch {
        url = "https://raw.githubusercontent.com/cachyos/kernel-patches/master/${cachyosDir}/all/0001-cachyos-base-all.patch";
        sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";  # Replace with actual hash
      };
    }
    {
      name = "bore-scheduler";
      patch = pkgs.fetchpatch {
        url = "https://raw.githubusercontent.com/cachyos/kernel-patches/master/${cachyosDir}/sched/0001-bore-cachy.patch";
        sha256 = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";  # Replace with actual hash
      };
    }
  ];
  
  # Build CachyOS kernel
  cachyos-kernel = (pkgs.linuxManualConfig {
    inherit (pkgs) stdenv;
    version = "${cachyosVersion}-cachyos-bore";
    modDirVersion = cachyosVersion;
    src = cachyos-src;
    configfile = cachyos-config;
    allowImportFromDerivation = true;
    kernelPatches = cachyos-patches;
  }).overrideAttrs (old: {
    passthru = old.passthru // {
      features = { ia32Emulation = true; efiBootStub = true; };
      modDirVersion = cachyosVersion;
    };
  });

  # ─────────────────────────────────────────────────────────────────────────
  # Kernel Selection Map
  # ─────────────────────────────────────────────────────────────────────────
  kernelPackagesMap = {
    # Zen: Optimized for desktop, gaming, audio. Pre-built.
    "zen" = pkgs.linuxPackages_zen;
    
    # Xanmod: Uses BORE scheduler. Pre-built.
    "xanmod" = pkgs.linuxPackages_xanmod_latest;
    
    # Latest stable kernel
    "latest" = pkgs.linuxPackages_latest;
    
    # CachyOS BORE (requires hash updates above)
    "cachyos-bore" = pkgs.linuxPackagesFor cachyos-kernel;
  };

  selectedKernel = kernelPackagesMap.${cfg.variant};

in {
  options.custom.kernel = {
    variant = lib.mkOption {
      type = lib.types.enum [ "zen" "xanmod" "latest" "cachyos-bore" ];
      default = "zen";
      description = ''
        Kernel package set. zen/xanmod/latest are pre-built; cachyos-bore is
        built from source (heavy) and requires allowCachyExperimental + real
        hashes filled into the cachyos-* fetchers in this module.
      '';
    };

    allowCachyExperimental = lib.mkEnableOption ''
      building the CachyOS-BORE kernel from source. Off by default because the
      cachyos-* fetchers in this module still carry placeholder sha256 hashes
      and the build is very heavy
    '';
  };

  config = {
    assertions = [
      {
        assertion = cfg.variant != "cachyos-bore" || cfg.allowCachyExperimental;
        message = ''
          custom.kernel.variant = "cachyos-bore" requires
          custom.kernel.allowCachyExperimental = true, and you must first replace
          the placeholder sha256-AAAA… hashes in modules/kernel.nix
          (cachyos-src / cachyos-config / cachyos-patches) with real ones.
        '';
      }
    ];

    # ───────────────────────────────────────────────────────────────────────
    # Apply Kernel
    # ───────────────────────────────────────────────────────────────────────
    boot.kernelPackages = lib.mkForce selectedKernel;

    # KVM modules live per-host in hardware-configuration.nix (kvm-amd on the
    # AMD host, kvm-intel on the Intel/Optimus hosts). Thermal policy lives in
    # modules/platform.nix (thermald for Intel CPUs; amd_pstate for AMD).

    # ───────────────────────────────────────────────────────────────────────
    # Desktop/Gaming Optimized Sysctl
    # ───────────────────────────────────────────────────────────────────────
    boot.kernel.sysctl = {
    # Memory management
    "vm.swappiness" = lib.mkDefault 10;
    "vm.dirty_ratio" = lib.mkDefault 10;
    "vm.dirty_background_ratio" = lib.mkDefault 5;
    "vm.vfs_cache_pressure" = lib.mkDefault 50;
    
    # Network performance
    "net.core.rmem_default" = lib.mkDefault 1048576;
    "net.core.wmem_default" = lib.mkDefault 1048576;
    "net.core.rmem_max" = lib.mkDefault 16777216;
    "net.core.wmem_max" = lib.mkDefault 16777216;
    "net.ipv4.tcp_fastopen" = lib.mkDefault 3;
    
    # Real-time audio
    "kernel.sched_rt_runtime_us" = lib.mkDefault 950000;
    };
  };
}

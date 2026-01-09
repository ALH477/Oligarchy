{ config, pkgs, lib, ... }:

# ============================================================================
# CachyOS-style Optimized Kernel Module
# ============================================================================
# 
# Option 1 (RECOMMENDED - works immediately): Use Zen kernel
#   - Similar low-latency optimizations as CachyOS BORE
#   - Pre-built, no compilation needed
#   - Set kernelChoice = "zen" below
#
# Option 2 (ADVANCED): Build CachyOS BORE from source
#   - Requires fetching correct hashes (see instructions below)
#   - Set kernelChoice = "cachyos-bore" and update hashes
#
# ============================================================================

let
  # ─────────────────────────────────────────────────────────────────────────
  # KERNEL SELECTION - Change this to switch kernels
  # ─────────────────────────────────────────────────────────────────────────
  # Options: "zen" | "xanmod" | "cachyos-bore" | "latest"
  kernelChoice = "zen";

  # ─────────────────────────────────────────────────────────────────────────
  # CachyOS BORE Configuration (only used if kernelChoice = "cachyos-bore")
  # ─────────────────────────────────────────────────────────────────────────
  # To get correct hashes:
  # 1. Set each sha256 to lib.fakeHash
  # 2. Run: nix build .#nixosConfigurations.nixos.config.system.build.toplevel
  # 3. Copy the correct hash from the error message
  # 4. Repeat for each fetchurl/fetchpatch
  
  cachyosVersion = "6.12.64";  # Use 6.12 LTS - stable with CachyOS patches
  cachyosDir = "6.12";
  
  cachyos-src = pkgs.fetchurl {
    url = "https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-${cachyosVersion}.tar.xz";
    # Get hash: nix-prefetch-url https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.12.64.tar.xz
    sha256 = "0000000000000000000000000000000000000000000000000000";  # UPDATE THIS
  };
  
  cachyos-config = pkgs.fetchurl {
    url = "https://raw.githubusercontent.com/CachyOS/linux-cachyos/master/linux-cachyos-bore/config";
    # Get hash: nix-prefetch-url <url>
    sha256 = "0000000000000000000000000000000000000000000000000000";  # UPDATE THIS
  };
  
  cachyos-patches = [
    {
      name = "cachyos-base-all";
      patch = pkgs.fetchpatch {
        url = "https://raw.githubusercontent.com/cachyos/kernel-patches/master/${cachyosDir}/all/0001-cachyos-base-all.patch";
        sha256 = "0000000000000000000000000000000000000000000000000000";  # UPDATE THIS
      };
    }
    {
      name = "bore-cachy";
      patch = pkgs.fetchpatch {
        url = "https://raw.githubusercontent.com/cachyos/kernel-patches/master/${cachyosDir}/sched/0001-bore-cachy.patch";
        sha256 = "0000000000000000000000000000000000000000000000000000";  # UPDATE THIS
      };
    }
  ];
  
  cachyos-kernel = (pkgs.linuxManualConfig {
    inherit (pkgs) stdenv;
    version = "${cachyosVersion}-cachyos-bore";
    modDirVersion = cachyosVersion;
    src = cachyos-src;
    configfile = cachyos-config;
    allowImportFromDerivation = true;
    kernelPatches = cachyos-patches;
  }).overrideAttrs (oldAttrs: {
    passthru = oldAttrs.passthru // {
      features = { ia32Emulation = true; efiBootStub = true; };
      modDirVersion = cachyosVersion;
    };
  });

  # ─────────────────────────────────────────────────────────────────────────
  # Kernel Package Selection
  # ─────────────────────────────────────────────────────────────────────────
  selectedKernel = {
    # Zen kernel - optimized for desktop, low latency, good for gaming
    # Similar to CachyOS optimizations, uses MuQSS/PDS scheduler
    "zen" = pkgs.linuxPackages_zen;
    
    # Xanmod - another optimized kernel, uses BORE scheduler by default
    "xanmod" = pkgs.linuxPackages_xanmod_latest;
    
    # Latest stable kernel from nixpkgs
    "latest" = pkgs.linuxPackages_latest;
    
    # Custom CachyOS BORE build (requires hash updates above)
    "cachyos-bore" = pkgs.linuxPackagesFor cachyos-kernel;
  }.${kernelChoice};

in {
  boot.kernelPackages = lib.mkForce selectedKernel;
  
  boot.kernelModules = lib.mkBefore [ "kvm-amd" ];
  
  # Thermald for better thermal management
  services.thermald.enable = true;
  
  # Kernel parameters optimized for desktop/gaming (applied regardless of kernel)
  boot.kernel.sysctl = {
    # Reduce swappiness for better responsiveness
    "vm.swappiness" = lib.mkDefault 10;
    # vm.max_map_count is set by programs.gamemode (Steam) - don't duplicate
    # Better I/O scheduling
    "vm.dirty_ratio" = lib.mkDefault 10;
    "vm.dirty_background_ratio" = lib.mkDefault 5;
  };
}

{ config, pkgs, lib, inputs, ... }:

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
  # ("zen" | "xanmod" | "latest" | "lts" | "cachyos-bore"). Set it in
  # configuration.nix or via the control center (writes
  # ~/.config/oligarchy/state.nix).
  cfg = config.custom.kernel;

  # ─────────────────────────────────────────────────────────────────────────
  # LTS (6.12) EOL tracking
  # ─────────────────────────────────────────────────────────────────────────
  # Nix has no real "now" available under pure evaluation (flakes force
  # pure-eval, which disables builtins.currentTime entirely). self.lastModified
  # is likewise unusable as a clock substitute: it's unset whenever the
  # working tree has uncommitted changes, which is common during normal
  # editing. Instead we use inputs.nixpkgs.lastModified — the pinned nixpkgs
  # input's own commit timestamp, sourced from flake.lock, therefore pure and
  # dirty-tree-immune. It only advances when `nix flake update` bumps the
  # nixpkgs input, so it's a conservative, one-directional lower bound on
  # "now": it can never exceed real wall-clock time, so once it crosses these
  # cutoffs, the real date has definitely also crossed them.
  #
  # Cutoffs (hardcoded Unix epoch seconds, computed offline via
  # `date -u -d "<date>" +%s` — no date arithmetic performed by Nix itself):
  #   2028-06-01T00:00:00Z = 1843430400  (approaching EOL)
  #   2028-12-01T00:00:00Z = 1859241600  (projected EOL per kernel.org LTS
  #                                       schedule / Greg K-H's extension)
  nixpkgsPinDate = inputs.nixpkgs.lastModified or 0;
  kernelEolApproachingCutoff = 1843430400; # 2028-06-01
  kernelEolPassedCutoff = 1859241600; # 2028-12-01

  kernelEolWarnings =
    lib.optional (cfg.variant == "lts" && nixpkgsPinDate >= kernelEolPassedCutoff) ''
      custom.kernel.variant = "lts" is pinned to pkgs.linuxPackages_6_12
      (Linux 6.12 LTS). Your nixpkgs input's own commit date is on/after
      2028-12-01 — Linux 6.12's projected upstream EOL — so 6.12 is very
      likely past end-of-life by now. Check kernel.org's LTS release page,
      then either bump modules/kernel.nix's "lts" entry to the current
      nixpkgs LTS attribute (and consider renaming it, e.g. "lts-6.1X",
      since nixpkgs has no generic auto-tracking LTS alias) or switch
      affected hosts/personas off "lts" until it's updated.
    ''
    ++ lib.optional (cfg.variant == "lts"
      && nixpkgsPinDate >= kernelEolApproachingCutoff
      && nixpkgsPinDate < kernelEolPassedCutoff) ''
      custom.kernel.variant = "lts" is pinned to pkgs.linuxPackages_6_12
      (Linux 6.12 LTS), whose projected upstream EOL is 2028-12-01. Your
      nixpkgs input's commit date is now within 6 months of that cutoff —
      plan to verify/re-pin modules/kernel.nix's "lts" entry to whatever
      nixpkgs' current LTS kernel is before then.
    '';

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

    # LTS: nixpkgs' current long-term-support line. Pre-built, most
    # predictable RT/audio behavior of the four (no rolling scheduler
    # patches). Pins to linuxPackages_6_12 (Linux 6.12 LTS, upstream EOL
    # projected Dec 2028 — see the kernelEol* warning above). NOTE: unlike
    # "latest" (nixpkgs itself keeps linuxPackages_latest pointed at the
    # newest stable kernel), nixpkgs has no generic "linuxPackages_lts" /
    # "linuxPackages_default" alias to bind to — this entry is a manually
    # pinned attribute and MUST be bumped by hand (e.g. to linuxPackages_6_1X,
    # or renamed to "lts-6.1X") once nixpkgs rolls its own LTS default past
    # 6.12.
    "lts" = pkgs.linuxPackages_6_12;

    # CachyOS BORE (requires hash updates above)
    "cachyos-bore" = pkgs.linuxPackagesFor cachyos-kernel;
  };

  selectedKernel = kernelPackagesMap.${cfg.variant};

in {
  options.custom.kernel = {
    variant = lib.mkOption {
      type = lib.types.enum [ "zen" "xanmod" "latest" "lts" "cachyos-bore" ];
      default = "zen";
      description = ''
        Kernel package set. zen/xanmod/latest/lts are pre-built; cachyos-bore
        is built from source (heavy) and requires allowCachyExperimental +
        real hashes filled into the cachyos-* fetchers in this module.

        lts pins to pkgs.linuxPackages_6_12 (Linux 6.12 LTS). It trades the
        zen/xanmod rolling schedulers for a long-term-support branch with
        more predictable RT/audio latency behavior — used by the "studio"
        persona for this reason. Linux 6.12's upstream EOL is currently
        projected for December 2028; this module emits a build-time warning
        (not a hard failure) once the nixpkgs pin's own commit date reaches
        that cutoff — see the kernelEol* let-bindings above.
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

    warnings = kernelEolWarnings;

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

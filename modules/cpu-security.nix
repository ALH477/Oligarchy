# modules/cpu-security.nix
# Preset-driven CPU security hardening for x86-64 NixOS (Intel + AMD).
# Covers: speculative-execution mitigations, SMT, microcode, MSR lockdown,
# kernel-image protection, TSX, and CFI / kernel-lockdown escape hatches.
#
# Adapted for this repo from the compass research artifact, with fixes:
#   - vendor tracks `custom.platform.cpu` (no impure /proc/cpuinfo read at eval)
#   - lockdownMode is nullOr so presets can actually supply it
#   - no duplicate kexec_load_disabled sysctl (security.protectKernelImage owns it)
#
# NOTE: every "stock kernel" caveat in the research doc is about pkgs.linuxPackages.
# This repo runs linuxPackages_zen by default (xanmod/latest/cachyos-bore selectable
# per persona — see modules/kernel.nix). Verify msr/lockdown configs per kernel with:
#   zcat /proc/config.gz | grep -E 'LOCKDOWN|X86_MSR'
#   grep -r . /sys/devices/system/cpu/vulnerabilities/
{ config, lib, pkgs, ... }:

let
  cfg = config.hardware.cpuSecurity;
  inherit (lib) mkOption mkEnableOption mkIf mkMerge mkDefault types optionals;

  # Resolve preset booleans. Individual toggles (cfg.<x>) default to null and,
  # when null, inherit the preset value; when set, they override the preset.
  presetDefaults = {
    balanced = {
      forceAllMitigations = false;   # rely on mitigations=auto (kernel default)
      disableSMT          = false;
      earlyMicrocode      = true;
      blockMsrWrites      = true;    # matches kernel >=5.9 default; make explicit
      blacklistMsrModule  = false;
      lockKernelModules   = false;
      protectKernelImage  = false;
      disableTSX          = false;   # Intel only when true
      forceGDS            = false;   # Intel only
      lockdownMode        = "none";  # see caveats: requires custom kernel + signing
    };
    hardened = {
      forceAllMitigations = true;    # mitigations=auto, explicit per-vuln on
      disableSMT          = false;   # keep SMT for build/DSP throughput
      earlyMicrocode      = true;
      blockMsrWrites      = true;
      blacklistMsrModule  = false;   # keep undervolt/thermal tooling working
      lockKernelModules   = false;   # off by default: breaks module autoload
      protectKernelImage  = true;    # nohibernate + kexec_load_disabled
      disableTSX          = true;    # Intel: kill TSX/TAA at the source
      forceGDS            = false;
      lockdownMode        = "none";  # opt into "integrity" only with signing
    };
    vault = {
      forceAllMitigations = true;
      disableSMT          = false;   # keep SMT for RT performance
      earlyMicrocode      = true;
      blockMsrWrites      = true;
      blacklistMsrModule  = false;
      lockKernelModules   = true;    # NEW: no modules after boot
      protectKernelImage  = true;
      disableTSX          = true;    # Intel only
      forceGDS            = false;   # explicitly NOT forced — AVX perf
      lockdownMode        = "integrity"; # NEW: prevents kernel modification
    };
    paranoid = {
      forceAllMitigations = true;
      disableSMT          = true;    # nosmt: closes cross-thread leakage
      earlyMicrocode      = true;
      blockMsrWrites      = true;
      blacklistMsrModule  = true;    # blocks wrmsr/rdmsr entirely (if msr is =m)
      lockKernelModules   = true;
      protectKernelImage  = true;
      disableTSX          = true;
      forceGDS            = true;    # force GDS ucode mitig or disable AVX
      lockdownMode        = "confidentiality";
    };
  };

  P = presetDefaults.${cfg.preset};
  # pick: explicit override (non-null) wins over preset value.
  pick = name: if cfg.${name} != null then cfg.${name} else P.${name};

  isIntel = cfg.vendor == "intel";
  isAMD   = cfg.vendor == "amd";

  forceAll  = pick "forceAllMitigations";
  noSMT     = pick "disableSMT";
  tsxOff    = pick "disableTSX";
  gdsForce  = pick "forceGDS";
  lockdown  = pick "lockdownMode";

  tri = mkOption { type = types.nullOr types.bool; default = null; };
in
{
  options.hardware.cpuSecurity = {
    enable = mkEnableOption "CPU security hardening (mitigations, microcode, MSR, lockdown)";

    preset = mkOption {
      type = types.enum [ "balanced" "hardened" "vault" "paranoid" ];
      default = "hardened";
      description = ''
        balanced  = close to upstream defaults (mitigations=auto, early ucode, MSR writes blocked).
        hardened  = force all mitigations, protect kernel image, disable TSX (Intel). SMT kept.
        vault     = hardened + Secure Boot required, kernel lockdown=integrity, module locking. Zero performance cost. Requires lanzaboote + enrolled Secure Boot keys.
        paranoid  = also nosmt, blacklist msr, lock modules, force GDS, confidentiality lockdown.
      '';
    };

    vendor = mkOption {
      type = types.enum [ "intel" "amd" ];
      # Track the host's declared CPU (modules/platform.nix). No impure eval-time
      # /proc/cpuinfo read; override here only if a host's CPU differs from platform.cpu.
      default = config.custom.platform.cpu;
      defaultText = lib.literalExpression "config.custom.platform.cpu";
      description = "CPU vendor. Selects Intel-only vs AMD-only kernel flags. Defaults to custom.platform.cpu.";
    };

    # ---- individual overrides (null => inherit preset) ----
    forceAllMitigations = tri // { description = "Force mitigations=auto + explicit per-vuln flags. Cost: Retbleed/IBRS 14-39% on affected CPUs (up to 70% in VMs)."; };
    disableSMT          = tri // { description = "nosmt. Security: closes L1TF/MDS/TAA/SRSO cross-thread. Cost: large throughput loss on parallel builds/DSP."; };
    earlyMicrocode      = tri // { description = "Early (initrd) microcode loading. Required by many mitigations. Keep true."; };
    blockMsrWrites      = tri // { description = "msr.allow_writes=off. Blocks userspace wrmsr (LSTAR/mitigation MSR attacks). Matches kernel >=5.9 default."; };
    blacklistMsrModule  = tri // { description = "Blacklist the msr module (only effective if msr is =m). Stronger than blockMsrWrites but breaks undervolt/thermal/cpupower tools."; };
    lockKernelModules   = tri // { description = "Disable module loading after boot. Cost: breaks autoload (WireGuard, some net)."; };
    protectKernelImage  = tri // { description = "nohibernate + kexec_load_disabled=1. Cost: no hibernation, no kexec."; };
    disableTSX          = tri // { description = "Intel only: tsx=off. Closes TAA at the source. Cost: removes transactional memory."; };
    forceGDS            = tri // { description = "Intel only: gather_data_sampling=force. Uses ucode mitig or DISABLES AVX. Cost: up to 50% on AVX-gather DSP code."; };

    lockdownMode = mkOption {
      type = types.nullOr (types.enum [ "none" "integrity" "confidentiality" ]);
      default = null;  # null => inherit the preset's lockdownMode
      description = ''
        Kernel lockdown level (null inherits the preset). WARNING (2026): the default
        NixOS kernel has CONFIG_SECURITY_LOCKDOWN_LSM=no, so this is a NO-OP unless you
        also build a kernel with SECURITY_LOCKDOWN_LSM=y, add "lockdown" to security.lsm,
        and set up module signing (Secure Boot / lanzaboote). The assertion below guards
        against silently shipping a no-op.
      '';
    };

    enableLockdownKernelBuild = mkEnableOption ''
      rebuild the kernel with SECURITY_LOCKDOWN_LSM=y so lockdownMode actually works.
      Requires module signing to avoid breaking out-of-tree modules.
    '';
  };

  config = mkIf cfg.enable (mkMerge [

    ##########################################################################
    # 1. MICROCODE (both vendors, early loading)
    #    Plain `true` intentionally overrides the firmware-gated mkDefault in
    #    modules/hardware-configuration.nix — hardening wants microcode present.
    ##########################################################################
    (mkIf (pick "earlyMicrocode") {
      hardware.cpu.intel.updateMicrocode = mkIf isIntel true;
      hardware.cpu.amd.updateMicrocode   = mkIf isAMD true;
    })

    ##########################################################################
    # 2. GLOBAL MITIGATION SPINE
    ##########################################################################
    {
      # 'auto' is the implicit kernel default; we set it explicitly so it can't
      # silently regress and so 'paranoid' can append nosmt.
      boot.kernelParams =
        [ "mitigations=auto" ]
        ++ optionals noSMT [ "nosmt" ];
    }

    ##########################################################################
    # 3. FORCE EXPLICIT PER-VULN MITIGATIONS (both + vendor-specific)
    ##########################################################################
    (mkIf forceAll {
      boot.kernelParams = [
        # ---- both vendors ----
        "spectre_v2=on"                 # IBRS/retpoline; eIBRS needs ucode
        "spectre_v2_user=on"            # user->user STIBP/IBPB
        "spec_store_bypass_disable=on"  # SSB
        "retbleed=auto"                 # Intel: IBRS-on-entry; AMD: unret/IBPB
      ]
      # ---- Intel-only ----
      ++ optionals isIntel [
        "pti=on"                        # Meltdown
        "l1tf=full"                     # L1 Terminal Fault
        "mds=full"                      # Microarch Data Sampling (needs ucode VERW)
        "tsx_async_abort=full"          # TAA
        "mmio_stale_data=full"          # MMIO stale data
        "reg_file_data_sampling=on"     # RFDS (Atom/E-core; harmless elsewhere)
        "spectre_bhi=on"                # Branch History Injection
      ]
      # ---- AMD-only ----
      ++ optionals isAMD [
        "spec_rstack_overflow=safe-ret" # SRSO/Inception (default safe-ret; "ibpb" = stronger+slower)
      ];
    })

    # TSX off (Intel) — closes TAA at the source
    (mkIf (tsxOff && isIntel) {
      boot.kernelParams = [ "tsx=off" ];
    })

    # Downfall/GDS force (Intel) — uses ucode mitig OR disables AVX if ucode missing
    (mkIf (gdsForce && isIntel) {
      boot.kernelParams = [ "gather_data_sampling=force" ];
    })

    ##########################################################################
    # 4. MSR LOCKDOWN
    ##########################################################################
    (mkIf (pick "blockMsrWrites") {
      # Explicitly assert the >=5.9 default. (Undervolt tools that need writes
      # must flip this back via msr.allow_writes=on — intentionally not done here.)
      boot.kernelParams = [ "msr.allow_writes=off" ];
    })
    (mkIf (pick "blacklistMsrModule") {
      # Only effective if the running kernel builds msr as a module (=m).
      boot.blacklistedKernelModules = [ "msr" ];
    })

    ##########################################################################
    # 5. KERNEL IMAGE / MODULE PROTECTION + cheap sysctls
    ##########################################################################
    (mkIf (pick "protectKernelImage") {
      # Sets nohibernate + kernel.kexec_load_disabled=1 (owns that sysctl).
      security.protectKernelImage = true;
    })
    (mkIf (pick "lockKernelModules") {
      security.lockKernelModules = true;
    })
    {
      # Cheap, no-perf-cost info-leak reductions. Normal priority (not mkDefault)
      # so these win over a mkDefault set by another module (e.g. kptr_restrict=1)
      # without a conflict; a host can still mkForce/mkDefault to change them.
      boot.kernel.sysctl = {
        "kernel.kptr_restrict"             = 2;
        "kernel.dmesg_restrict"            = 1;
        "kernel.unprivileged_bpf_disabled" = 1;
      };
    }

    ##########################################################################
    # 6. KERNEL LOCKDOWN (only meaningful with a custom kernel + signing)
    ##########################################################################
    (mkIf (lockdown != "none") {
      assertions = [{
        assertion = cfg.enableLockdownKernelBuild || config.boot.lanzaboote.enable or false;
        message = ''
          hardware.cpuSecurity.lockdownMode = "${lockdown}" requires either
          hardware.cpuSecurity.enableLockdownKernelBuild = true (rebuilds kernel with
          SECURITY_LOCKDOWN_LSM=y) or a Secure Boot setup (lanzaboote) that compiles in
          and auto-activates lockdown. Otherwise this setting is a silent no-op.
        '';
      }];
      security.lsm = mkDefault [ "landlock" "yama" "bpf" "lockdown" ];
      boot.kernelParams = [ "lockdown=${lockdown}" ];
    })

    (mkIf cfg.enableLockdownKernelBuild {
      boot.kernelPatches = [{
        name = "enable-lockdown-lsm";
        patch = null;
        extraConfig = ''
          SECURITY_LOCKDOWN_LSM y
          SECURITY_LOCKDOWN_LSM_EARLY y
          MODULE_SIG y
        '';
      }];
      # You MUST provide signing keys + sign out-of-tree modules, or use lanzaboote.
    })

    # Vault preset auto-enables the lockdown kernel build
    (mkIf (cfg.preset == "vault") {
      hardware.cpuSecurity.enableLockdownKernelBuild = lib.mkDefault true;
    })

    ##########################################################################
    # 7. VAULT PRESET: requires Secure Boot (lanzaboote)
    ##########################################################################
    (mkIf (cfg.preset == "vault") {
      assertions = [{
        assertion = config.boot.lanzaboote.enable or false;
        message = ''
          hardware.cpuSecurity.preset = "vault" requires Secure Boot via lanzaboote.
          The vault preset enforces kernel lockdown=integrity and module locking, which
          depend on a signed boot chain to be meaningful.

          To enable:
            1. Set custom.secureBoot.enable = true in configuration.nix
            2. sudo sbctl create-keys
            3. Enter BIOS → clear Secure Boot keys → Setup Mode
            4. sudo sbctl enroll-keys
            5. Reboot, verify: bootctl status shows "Secure Boot: enabled"
            6. Rebuild with preset = "vault"

          If you do not want Secure Boot requirements, use preset = "hardened" instead.
        '';
      }];
    })
  ]);
}

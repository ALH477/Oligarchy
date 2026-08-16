{ config, lib, pkgs, ... }:

# ============================================================================
# Hardware platform abstraction
# ============================================================================
# Extracts the GPU / CPU / AI-acceleration decisions that used to be hardcoded
# for the Framework 16 AMD board so the same tree can also target pure-Intel and
# Intel + Nvidia Optimus laptops. The `amd` + `framework` defaults reproduce the
# original Framework-16 configuration exactly, so the `nixos` target is unchanged.
# ============================================================================

with lib;

let
  cfg = config.custom.platform;
  isOptimus = cfg.gpu == "nvidia-optimus";
in
{
  options.custom.platform = {
    gpu = mkOption {
      type = types.enum [ "amd" "intel" "nvidia-optimus" ];
      default = "amd";
      description = "Primary GPU stack to configure.";
    };

    cpu = mkOption {
      type = types.enum [ "amd" "intel" ];
      default = "amd";
      description = "CPU vendor (selects pstate/thermal policy).";
    };

    displayGpu = mkOption {
      type = types.enum [ "dgpu" "igpu" ];
      default = "dgpu";
      description = ''
        Which AMD GPU client apps (games, Steam, anything launched from
        Hyprland) render on, on hosts with both an iGPU and a dGPU, via
        Mesa's DRI_PRIME device-select. "dgpu" (default) prioritizes the
        discrete GPU; "igpu" pins client rendering to the integrated GPU
        for battery/thermal efficiency. Only applied when
        custom.platform.gpu == "amd".

        This does NOT affect Hyprland/Aquamarine's own backend device — the
        compositor always uses whatever Mesa/KMS picks by default (the
        iGPU). Do not try to steer Aquamarine's own device (e.g. via
        AQ_DRM_DEVICES) to the dGPU: it has no display engine path of its
        own (see docs/dgpu-steam-forcing.md), and telling the compositor's
        backend to open it as primary is a fatal, unrecoverable crash
        (CCompositor::initServer -> throwError -> SIGABRT) with no
        fallback — this took the whole session and greetd down when tried.
      '';
    };

    dgpuPciId = mkOption {
      type = types.str;
      default = "0000:03:00.0"; # Navi 33 / RX 7700S dGPU expansion module
      description = "PCI bus id of the discrete AMD GPU (from `lspci`).";
    };

    igpuPciId = mkOption {
      type = types.str;
      default = "0000:c5:00.0"; # Phoenix1 780M, drives eDP
      description = "PCI bus id of the integrated AMD GPU (from `lspci`).";
    };

    framework = mkOption {
      type = types.bool;
      default = true;
      description = "Apply Framework-specific tweaks (USB quirks, fan control) common to both the 13 and 16.";
    };

    frameworkModel = mkOption {
      type = types.nullOr (types.enum [ "13" "16" ]);
      default = if cfg.framework then "16" else null;
      description = ''
        Which Framework chassis this is, for banner/display text only (the
        16-specific "You are based" boot banner, the boot-intro bottom
        text). Has no effect on kernel params, fan control, or USB quirks —
        those are shared by `framework = true` regardless of model. Leave
        null on non-Framework hardware.
      '';
    };

    hasDgpu = mkOption {
      type = types.bool;
      default = cfg.gpu == "amd";
      description = ''
        Whether this host actually has a second, discrete AMD GPU to route
        client-app rendering to (e.g. the Framework 16 expansion-bay dGPU).
        The Framework 13 (and a bare Framework 16 without the dGPU module)
        have only the iGPU — set this to false there so displayGpu/dgpuPciId
        DRI_PRIME routing is skipped instead of pointing at a PCI device
        that doesn't exist.
      '';
    };

    nvidia = {
      open = mkOption {
        type = types.bool;
        default = true;
        description = "Use the open Nvidia kernel module (Turing/RTX 20xx and newer).";
      };
      intelBusId = mkOption {
        type = types.str;
        default = "";
        description = "Intel iGPU PCI bus id for PRIME, e.g. \"PCI:0:2:0\".";
      };
      nvidiaBusId = mkOption {
        type = types.str;
        default = "";
        description = "Nvidia dGPU PCI bus id for PRIME, e.g. \"PCI:1:0:0\".";
      };
    };
  };

  config = mkMerge [
    # ── Assertions ──────────────────────────────────────────────────────────
    {
      assertions = [
        {
          assertion = !isOptimus || (cfg.nvidia.intelBusId != "" && cfg.nvidia.nvidiaBusId != "");
          message = ''
            custom.platform.gpu = "nvidia-optimus" requires both
            custom.platform.nvidia.intelBusId and .nvidiaBusId to be set.
            Find them with: lspci | grep -E 'VGA|3D|Display'  (convert "01:00.0" -> "PCI:1:0:0").
          '';
        }
      ];
    }

    # ── GPU: AMD (Framework 16 default — reproduces the original config) ─────
    (mkIf (cfg.gpu == "amd") {
      boot.kernelParams = [
        "amdgpu.abmlevel=0"
        "amdgpu.sg_display=0"
        "amdgpu.exp_hw_support=1"
      ];
      boot.initrd.kernelModules = [ "amdgpu" ];
      boot.kernelModules = [ "amdgpu" ];
      hardware.graphics.extraPackages = with pkgs; [
        rocmPackages.clr
        rocmPackages.clr.icd
      ];
      services.ollamaAgentic.acceleration = mkDefault "rocm";
      services.ollamaAgentic.advanced.rocm.gfxVersionOverride = mkDefault "11.0.2"; # RDNA3
    })

    # ── GPU: pure Intel ──────────────────────────────────────────────────────
    # The iGPU userspace + i915 module are provided by nixos-hardware's
    # common-gpu-intel (wired per-host in flake.nix).
    (mkIf (cfg.gpu == "intel") {
      environment.sessionVariables.LIBVA_DRIVER_NAME = "iHD";
      services.ollamaAgentic.acceleration = mkDefault null; # CPU inference
    })

    # ── GPU: Intel + Nvidia Optimus (PRIME render offload) ───────────────────
    # videoDrivers, prime.offload.enable and the `nvidia-offload` command come
    # from nixos-hardware's common-gpu-nvidia (prime.nix); the Intel iGPU (i915,
    # media driver) from common-gpu-intel — both wired per-host in flake.nix.
    # This branch supplies the rest (bus ids, open module, CUDA, etc.).
    (mkIf isOptimus {
      environment.sessionVariables.LIBVA_DRIVER_NAME = "iHD";

      hardware.nvidia = {
        modesetting.enable = true;
        open = cfg.nvidia.open;
        nvidiaSettings = true;
        powerManagement.enable = true;
        powerManagement.finegrained = true; # dGPU sleeps when offload-idle
        package = config.boot.kernelPackages.nvidiaPackages.stable;
        prime = {
          intelBusId = cfg.nvidia.intelBusId;
          nvidiaBusId = cfg.nvidia.nvidiaBusId;
        };
      };

      # CUDA for the local AI stack (ollama cuda image + container runtime)
      hardware.nvidia-container-toolkit.enable = true;
      services.ollamaAgentic.acceleration = mkDefault "cuda";
    })

    # ── CPU: AMD ─────────────────────────────────────────────────────────────
    (mkIf (cfg.cpu == "amd") {
      boot.kernelParams = [ "amd_pstate=active" ];
    })

    # ── CPU: Intel ───────────────────────────────────────────────────────────
    (mkIf (cfg.cpu == "intel") {
      services.thermald.enable = true; # Intel-only; manages thermals on Intel CPUs
    })

    # ── Framework-16-specific tweaks ─────────────────────────────────────────
    (mkIf cfg.framework {
      boot.kernelParams = [
        "usbcore.autosuspend=-1"
        # Prefer single bandwidth schedule under multi USB-audio; dual schemes
        # add scheduling complexity on AMD XHCI (c5:00.3 HC death thrash 2026-07-11).
        "usbcore.use_both_schemes=n"
        # DO NOT force xhci_hcd.quirks=0x40 (XHCI_TRUST_TX_LENGTH). That global
        # quirk co-occurred with "stop endpoint" / "HC died" under dual isoc
        # USB audio patchbay thrash on 1022:15b9. Let the driver pick AMD quirks.
        "usb-storage.quirks=:u"
      ];

      # ── Fan control ────────────────────────────────────────────────────────
      # The fw-fanctrl module is wired in from flake.nix but was never enabled,
      # which left the EC's stock curve as the *only* thermal actuator. That
      # curve is tuned for light desktop use and lags badly under a sustained
      # all-core load (nix builds, cargo), so the package rides 85-95C and the
      # fans only wake up once it is already too late.
      #
      # `agile` is the `medium` speed curve (15% -> 40C, 30% -> 60C, 40% -> 70C,
      # 80% -> 75C, 100% -> 85C) with a 15s moving average and a 3s update tick
      # instead of medium's 30s/5s, so it actually tracks bursty build load
      # rather than smoothing it away. On battery we fall back to `lazy` for
      # runtime and noise.
      hardware.fw-fanctrl = {
        enable = true;
        config = {
          defaultStrategy = "agile";
          strategyOnDischarging = "lazy";
        };
      };

      # Framework hardware check: any genuine Framework board (13 or 16) gets
      # told it's based, printed straight to the boot console before the
      # splash/display-manager claim the tty.
      systemd.services.framework-based-banner = {
        description = "Tell the user they are based (Framework ${cfg.frameworkModel or "?"} detected)";
        wantedBy = [ "sysinit.target" ];
        after = [ "systemd-udevd.service" ];
        before = [ "boot-intro-player.service" "display-manager.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = pkgs.writeShellScript "framework-based-banner" ''
            printf '\n\033[1;32mYou are based.\033[0m\n' > /dev/console 2>/dev/null || true
          '';
        };
      };
    })
  ];
}

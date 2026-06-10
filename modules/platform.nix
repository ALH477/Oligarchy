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

    framework = mkOption {
      type = types.bool;
      default = true;
      description = "Apply Framework-16-specific tweaks (USB quirks, fan control).";
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
        "usbcore.use_both_schemes=y"
        "xhci_hcd.quirks=0x40"
        "usb-storage.quirks=:u"
      ];
    })
  ];
}

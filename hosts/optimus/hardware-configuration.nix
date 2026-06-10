{ config, lib, pkgs, modulesPath, ... }:

# ============================================================================
# Host hardware: Intel + Nvidia Optimus laptop  (nixosConfigurations.nixos-optimus)
# ============================================================================
# This is a STUB. After installing on the real machine, regenerate the storage
# section with `nixos-generate-config` (or fill the FILL-IN markers below).
#
# GPU behaviour (PRIME render offload, open Nvidia module, CUDA) comes from
# custom.platform.gpu = "nvidia-optimus" in flake.nix. You MUST also set the
# PRIME PCI bus ids there (or here) — find them with:
#     lspci | grep -E 'VGA|3D|Display'      # e.g. "00:02.0" and "01:00.0"
# then convert "01:00.0" -> "PCI:1:0:0".
# ============================================================================

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [
    "nvme" "xhci_pci" "thunderbolt" "usbhid" "uas" "sd_mod"
  ];
  boot.initrd.kernelModules = [ ];

  boot.kernelModules = [
    "kvm-intel"
    "btusb"        # Bluetooth USB
    "btintel"      # Intel Bluetooth
  ];
  boot.extraModulePackages = [ ];

  # ── Filesystems — FILL IN real UUIDs (nixos-generate-config) ──────────────
  fileSystems."/" = {
    device = "/dev/disk/by-uuid/FILL-IN-ROOT-UUID";
    fsType = "ext4";
    options = [ "noatime" "nodiratime" ];
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/FILL-IN-BOOT-UUID";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  swapDevices = [ ];  # swapfile is configured in configuration.nix

  networking.useDHCP = lib.mkDefault true;
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
}

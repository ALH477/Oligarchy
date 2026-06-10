{ config, lib, pkgs, modulesPath, ... }:

# ============================================================================
# Host hardware: pure-Intel laptop  (nixosConfigurations.nixos-intel)
# ============================================================================
# This is a STUB. After installing on the real machine, regenerate the storage
# section with `nixos-generate-config` (or fill the FILL-IN markers below) and
# commit the result. GPU/AI behaviour comes from custom.platform.gpu = "intel"
# (set in flake.nix), not from here.
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

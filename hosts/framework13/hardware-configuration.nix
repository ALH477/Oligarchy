{ config, lib, pkgs, modulesPath, ... }:

# ============================================================================
# Host hardware: Framework 13 AMD 7040  (nixosConfigurations.nixos-fw13)
# ============================================================================
# This is a STUB, unverified against real Framework 13 hardware (the
# maintainer's own units are Framework 16 + RISC-V; see CLAUDE.md). After
# installing on the real machine, regenerate the storage section with
# `nixos-generate-config` (or fill the FILL-IN markers below) and commit the
# result. GPU/AI behaviour comes from custom.platform in flake.nix (gpu =
# "amd", hasDgpu = false — the 13 has no expansion-bay dGPU slot), not here.
#
# WiFi/Bluetooth modules below are copied from the Framework 16's
# ../../modules/hardware-configuration.nix on the assumption both boards
# ship the same MediaTek card; confirm with `lspci -k` after install and
# adjust boot.kernelModules if the 13 uses a different card.
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
    "kvm-amd"
    # Network modules — assumed same MediaTek WiFi/BT card as the Framework
    # 16; verify with `lspci -k` after first boot.
    "mt7921e"      # MediaTek WiFi
    "btusb"        # Bluetooth USB
    "btmtk"        # MediaTek Bluetooth
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

  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  hardware.firmware = with pkgs; [
    linux-firmware
  ];
}

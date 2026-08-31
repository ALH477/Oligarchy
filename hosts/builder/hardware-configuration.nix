{ config, lib, pkgs, modulesPath, ... }:

# ============================================================================
# Host hardware: headless CI build server  (nixosConfigurations.builder)
# ============================================================================
# This is a STUB. After installing on the real machine, regenerate the storage
# section with `nixos-generate-config --show-hardware-config` and commit the
# result, replacing the FILL-IN markers below.
#
# CPU vendor is NOT set here — it comes from `custom.platform.cpu` in
# flake.nix, which is also what selects the nested-virtualisation modprobe
# line in modules/ci-builder.nix. Set it there, once, and both follow.
#
# Sizing this box (measured from the gate definitions, not guessed):
#   RAM   the two-node p2p gates run 2 x 2048 MiB guests; plugins-tier2-runtime
#         runs a 4096 MiB guest with a 512 MiB microVM inside it. 32 GiB is
#         comfortable, 16 GiB is the floor if you never run gates in parallel.
#   DISK  `nix build .#malwareScan` realizes the entire system closure —
#         measured at 4096 paths / 48.6 GiB (docs/p2p-substituter-roadmap.md
#         §3.1). With a few generations retained, budget 250 GiB of SSD.
#   CPU   nested-virt capable, and it must actually be enabled in firmware:
#         `plugins-tier2-runtime` boots a guest inside a guest and asserts
#         /dev/kvm exists in the inner one.
# ============================================================================

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  boot.initrd.availableKernelModules = [
    "nvme"
    "xhci_pci"
    "ahci"
    "usbhid"
    "uas"
    "sd_mod"
  ];
  boot.initrd.kernelModules = [ ];

  # KVM module for this box's CPU. modules/ci-builder.nix sets the *nested*
  # parameter for whichever of these applies, driven by custom.platform.cpu;
  # loading both here is harmless (only the matching one initialises) and
  # keeps this file vendor-agnostic until you fill it in.
  boot.kernelModules = [
    "kvm-amd"
    "kvm-intel"
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

  # A build server benefits from real swap far more than a laptop does: a
  # parallel `nix build` of several VM gates can spike well past RAM.
  swapDevices = [ ];

  networking.useDHCP = lib.mkDefault true;
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";

  hardware.enableRedistributableFirmware = lib.mkDefault true;
}

# Fixture: what nixos-generate-config --show-hardware-config prints for a
# Framework 16 with an ext4 root and an ESP (UUIDs invented).
{ lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];
  boot.initrd.availableKernelModules = [ "nvme" "xhci_pci" "thunderbolt" "usbhid" "uas" "sd_mod" ];
  boot.kernelModules = [ "kvm-amd" ];
  fileSystems."/" = { device = "/dev/disk/by-uuid/0f0f0f0f-1111-4222-8333-444444444444"; fsType = "ext4"; };
  fileSystems."/boot" = { device = "/dev/disk/by-uuid/ABCD-1234"; fsType = "vfat"; options = [ "fmask=0077" "dmask=0077" ]; };
  swapDevices = [ ];
  networking.useDHCP = lib.mkDefault true;
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}

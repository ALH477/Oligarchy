# Fixture: a BIOS laptop with btrfs on LUKS (UUIDs invented).
{ lib, modulesPath, ... }:
{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];
  boot.initrd.availableKernelModules = [ "ahci" "xhci_pci" "sd_mod" ];
  boot.initrd.luks.devices.luks-root.device = "/dev/disk/by-uuid/11111111-0000-4000-8000-000000000001";
  fileSystems."/" = { device = "/dev/mapper/luks-root"; fsType = "btrfs"; options = [ "subvol=@" ]; };
  swapDevices = [{ device = "/dev/mapper/luks-swap"; }];
  networking.useDHCP = lib.mkDefault true;
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
}

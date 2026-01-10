{ config, lib, pkgs, modulesPath, ... }:

{
  imports = [
    (modulesPath + "/installer/scan/not-detected.nix")
  ];

  # ──────────────────────────────────────────────────────────────────────────
  # Boot Modules
  # ──────────────────────────────────────────────────────────────────────────
  boot.initrd.availableKernelModules = [ 
    "nvme" 
    "xhci_pci" 
    "thunderbolt" 
    "usbhid" 
    "uas" 
    "sd_mod"
  ];
  boot.initrd.kernelModules = [ ];
  
  boot.kernelModules = [ 
    "kvm-amd"
    # Network modules for Framework 16
    "mt7921e"      # MediaTek WiFi (Framework WiFi card)
    "btusb"        # Bluetooth USB
    "btintel"      # Intel Bluetooth (if present)
    "btmtk"        # MediaTek Bluetooth
  ];
  boot.extraModulePackages = [ ];

  # ──────────────────────────────────────────────────────────────────────────
  # Filesystems
  # ──────────────────────────────────────────────────────────────────────────
  # NOTE: Update UUIDs after installation
  fileSystems."/" = {
    device = "/dev/disk/by-uuid/d884532d-a9f2-4357-91f3-4f98249d405c";
    fsType = "ext4";
    options = [ "noatime" "nodiratime" ];
  };

  fileSystems."/boot" = {
    device = "/dev/disk/by-uuid/3736-204A";
    fsType = "vfat";
    options = [ "fmask=0077" "dmask=0077" ];
  };

  swapDevices = [ ];  # Defined in configuration.nix via swapfile

  # ──────────────────────────────────────────────────────────────────────────
  # Networking
  # ──────────────────────────────────────────────────────────────────────────
  networking.useDHCP = lib.mkDefault true;

  # ──────────────────────────────────────────────────────────────────────────
  # Platform
  # ──────────────────────────────────────────────────────────────────────────
  nixpkgs.hostPlatform = lib.mkDefault "x86_64-linux";
  
  # AMD microcode updates
  hardware.cpu.amd.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;
  
  # Firmware for WiFi/Bluetooth
  hardware.firmware = with pkgs; [
    linux-firmware
  ];
}

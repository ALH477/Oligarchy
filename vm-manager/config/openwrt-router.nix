{ lib, ... }:

# ============================================================================
# OpenWRT Router VM
# ============================================================================
# 
# Lightweight router VM using OpenWRT
# Resources: 512MB RAM, 1 core, 512MB storage
# Network: Bridged with NIC passthrough
#
# Download OpenWRT:
#   wget https://downloads.openwrt.org/releases/24.10.5/targets/x86/generic/openwrt-24.10.5-x86-generic-generic-ext4-combined.img.gz
#   gunzip openwrt-24.10.5-x86-generic-generic-ext4-combined.img.gz
#   qemu-img convert -O qcow2 openwrt-24.10.5-x86-generic-generic-ext4-combined.img ~/vms/openwrt-router.qcow2
#
# SHA256: 5979270b2ff86d2b3bd908bf8dcdb7efe4c1cf0f7525cc1d99227d38b913fb1e
#
# ============================================================================

{
  custom.vm.quickemu = {
    enable = lib.mkForce true;
    name = "openwrt-router";
    
    # Minimal resources for router
    cores = 1;
    memory = 512;
    diskSize = "512M";
    
    # OpenWRT
    os = "openwrt";
    bootOrder = "disk";
    
    # Use local disk image (download and convert first)
    diskImage = ~/vms/openwrt-router.qcow2;
    
    # Bridged networking
    network = {
      type = "bridge";
      bridge = "br0";
    };
    
    # PCI NIC passthrough for direct hardware access
    # pciDevice = "0000:03:00.0";  # Uncomment and set your NIC PCI ID
    
    # Headless - no display
    spice = lib.mkForce false;
    vnc = lib.mkForce false;
    
    # Minimal resource settings
    preallocation = "off";
    cpuHost = true;
  };
}

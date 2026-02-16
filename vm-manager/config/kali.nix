{ lib, ... }:

# ============================================================================
# Kali Linux VM
# ============================================================================
# 
# Security/hacking VM
# Core: last core (e.g., core 5 on 6-core, core 3 on 4-core)
# RAM: 4GB
#
# ============================================================================

{
  custom.vm.quickemu = {
    enable = lib.mkForce true;
    name = "kali-linux";
    cores = 1;
    memory = 4096;
    diskSize = "80G";
    os = "kali";
    bootOrder = "disk";
    cpuHost = true;
    ssh = true;
    portForwards = [ "2223:22" ];
    
    # Enable display for Kali GUI tools
    spice = true;
    vnc = false;
    
    # Security tools options
    preallocation = "full";
    cpuPinning = true;
    
    # USB passthrough for hardware hacking
    # usbDevice = "1050:0407";  # YubiKey example
  };
}

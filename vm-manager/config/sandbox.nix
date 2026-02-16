{ lib, ... }:

# ============================================================================
# Coding Sandbox VM - Arch Linux
# ============================================================================
# 
# Headless Arch Linux VM for coding agents
# Core: second-to-last (e.g., core 5 on 6-core, core 3 on 4-core)
# RAM: 2-4GB
#
# ============================================================================

{
  custom.vm.quickemu = {
    enable = lib.mkForce true;
    name = "coding-sandbox";
    cores = 1;
    memory = 3072;
    diskSize = "64G";
    os = "arch";
    bootOrder = "disk";
    cpuHost = true;
    ssh = true;
    portForwards = [ "2222:22" ];
    
    # For headless, we don't need display
    spice = lib.mkForce false;
    vnc = lib.mkForce false;
    
    # Performance options
    preallocation = "full";
    cpuPinning = true;
  };
}

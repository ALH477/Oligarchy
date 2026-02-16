{ config, pkgs, lib, ... }:

# ============================================================================
# Quickemu VM Module
# ============================================================================
# 
# This module provides a lightweight VM management using quickemu.
# Ideal for headless VMs like coding sandboxes and Kali Linux.
#
# ============================================================================

{
  options.custom.vm.quickemu = {
    enable = lib.mkEnableOption "Quickemu-based VM";
    
    name = lib.mkOption {
      type = lib.types.str;
      default = "quickemu-vm";
      description = "Name of the VM.";
    };
    
    cores = lib.mkOption {
      type = lib.types.int;
      default = 1;
      description = "Number of CPU cores.";
    };
    
    memory = lib.mkOption {
      type = lib.types.int;
      default = 2048;
      description = "Memory in MB.";
    };
    
    diskSize = lib.mkOption {
      type = lib.types.str;
      default = "32G";
      description = "Disk size (e.g., 32G).";
    };
    
    diskImg = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/quickemu/images";
      description = "Directory for disk images.";
    };
    
    iso = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "ISO image to boot from.";
    };
    
    diskImage = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Pre-built disk image to use.";
    };
    
    os = lib.mkOption {
      type = lib.types.enum [ "arch" "debian" "fedora" "kali" "ubuntu" "windows" "macos" "openwrt" ];
      default = "arch";
      description = "Operating system for quickemu defaults.";
    };
    
    pciDevice = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "PCI device to passthrough (e.g., 0000:01:00.0).";
    };
    
    usbDevice = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "USB device to passthrough (e.g., 046d:c52b).";
    };
    
    portForwards = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "Port forwards in format host:guest.";
      example = [ "8080:80" "2222:22" ];
    };
    
    spice = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable SPICE display.";
    };
    
    ssh = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable SSH port forwarding (port 2222 -> 22).";
    };
    
    vnc = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable VNC display.";
    };
    
    webdav = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable WebDAV sharing.";
    };
    
    sharedDir = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Directory to share with guest.";
    };
    
    cpuHost = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Pass through host CPU (better performance).";
    };
    
    keyboard = lib.mkOption {
      type = lib.types.str;
      default = "en-us";
      description = "Keyboard layout.";
    };
    
    bootOrder = lib.mkOption {
      type = lib.types.enum [ "disk" "cd" "network" ];
      default = "disk";
      description = "Boot order.";
    };
    
    tpm = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable TPM 2.0.";
    };
    
    secureboot = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable UEFI Secure Boot.";
    };
    
    preallocation = lib.mkOption {
      type = lib.types.enum [ "off" "metadata" "falloc" "full" ];
      default = "metadata";
      description = "Disk preallocation method.";
    };
    
    cpuAffinity = lib.mkOption {
      type = lib.types.nullOr lib.types.int;
      default = null;
      description = "Pin VM to specific CPU core.";
    };
    
    cpuPinning = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable CPU pinning for the VM.";
    };
    
    network = {
      type = lib.mkOption {
        type = lib.types.enum [ "nat" "bridge" "host" ];
        default = "nat";
        description = "Network type: nat, bridged, or host-only.";
      };
      
      bridge = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "Bridge interface for bridged networking (e.g., br0).";
      };
      
      macAddress = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = "MAC address for the VM's network interface.";
      };
    };
  };

  config = let
    cfg = config.custom.vm.quickemu;
  in lib.mkIf cfg.enable {
    environment.systemPackages = [ pkgs.quickemu ];

    systemd.services.quickemu-vm = {
      description = "Quickemu VM - ${cfg.name}";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      
      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = 10;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ "/var/lib/quickemu" "/var/run" ];
        
        ExecStart = let
          vmName = cfg.name;
          vmDir = "/var/lib/quickemu/${vmName}";
          
          portFwd = lib.concatStringsSep " " (map (p: "-p ${p}") cfg.portForwards)
            ++ lib.optional cfg.ssh " -p 2222:22";
          
          deviceFlags = lib.optionals (cfg.pciDevice != null) [ "-pci ${cfg.pciDevice}" ]
            ++ lib.optionals (cfg.usbDevice != null) [ "-usb ${cfg.usbDevice}" ];
          
          displayFlags = lib.optionalString cfg.spice " --spice"
            ++ lib.optionalString cfg.vnc " --vnc";
          
          shareFlags = lib.optionals (cfg.sharedDir != null) [ "--shared-dir ${cfg.sharedDir}" ]
            ++ lib.optional cfg.webdav "--webdav";
          
          cpuFlags = lib.optionalString cfg.cpuHost " --host-cpu"
            ++ lib.optional (cfg.cpuPinning && cfg.cpuAffinity != null) " --cpu ${toString cfg.cpuAffinity}";
          
        in pkgs.writeShellScript "start-quickemu-${vmName}" ''
          set -e
          
          VM_DIR="${vmDir}"
          VM_NAME="${vmName}"
          
          mkdir -p "$VM_DIR"
          
          cat > "$VM_DIR/quickemu.conf" << EOF
          os=${cfg.os}
          cpu_cores=${toString cfg.cores}
          memory=${toString cfg.memory}
          disk_size=${cfg.diskSize}
          disk_img=${cfg.diskImg}/${vmName}.qcow2
          iso=${if cfg.iso != null then cfg.iso else ""}
          img=${if cfg.diskImage != null then cfg.diskImage else ""}
          boot=${cfg.bootOrder}
          keyboard_layout=${cfg.keyboard}
          preallocation=${cfg.preallocation}
          ${lib.optionalString cfg.tpm "tpm=on"}
          ${lib.optionalString cfg.secureboot "secureboot=on"}
          ${lib.optionalString (cfg.network.type == "bridge" && cfg.network.bridge != null) "bridge=${cfg.network.bridge}"}
          ${lib.optionalString (cfg.network.macAddress != null) "mac=${cfg.network.macAddress}"}
          ${lib.optionalString (cfg.network.type == "host") "network=host"}
          EOF
          
          cd "$VM_DIR"
          
          exec quickemu --vm "${vmName}.conf" \
            --display spice \
            ${portFwd} \
            ${lib.concatStringsSep " " deviceFlags} \
            ${lib.concatStringsSep " " displayFlags} \
            ${lib.concatStringsSep " " shareFlags} \
            ${cpuFlags}
        '';
        
        ExecStop = "${pkgs.coreutils}/bin/kill -TERM $MAINPID";
      };
    };

    users.users.asher.extraGroups = [ "kvm" "libvirt" "input" ];
  };
}

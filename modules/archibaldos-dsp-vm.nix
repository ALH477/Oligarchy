{ config, pkgs, lib, ... }:

# ============================================================================
# ArchibaldOS DSP Coprocessor VM Module
# ============================================================================
# 
# This module creates an isolated VM running ArchibaldOS for real-time
# digital signal processing. It uses CPU isolation and VFIO passthrough
# for deterministic audio latency.
#
# Prerequisites:
#   1. Add archibaldos input to flake.nix
#   2. Identify your USB audio interface PCI ID: lspci -nn | grep -i audio
#   3. Enable IOMMU in BIOS (AMD-Vi / Intel VT-d)
#
# ============================================================================

let
  cfg = config.custom.archibaldos-dsp-vm;
  
in {
  options.custom.archibaldos-dsp-vm = {
    enable = lib.mkEnableOption "ArchibaldOS DSP coprocessor VM";
    
    isolatedCpu = lib.mkOption {
      type = lib.types.int;
      default = 0;
      description = "CPU core to isolate for the DSP VM.";
    };
    
    memoryMB = lib.mkOption {
      type = lib.types.int;
      default = 1536;
      description = "Memory allocation for the VM in MB.";
    };
    
    hugepages = lib.mkOption {
      type = lib.types.int;
      default = 1024;
      description = "Number of 2MB hugepages to reserve.";
    };
    
    audioDevice = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable VFIO passthrough of USB audio interface.";
      };
      
      pciId = lib.mkOption {
        type = lib.types.str;
        default = "0000:00:1b.0";
        description = "PCI address of audio device (from lspci -nn).";
        example = "0000:00:1b.0";
      };
      
      vendorDevice = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Vendor:Device ID for VFIO binding (e.g., '1022:15e3').";
        example = "1022:15e3";
      };
    };
    
    jackPort = lib.mkOption {
      type = lib.types.port;
      default = 4713;
      description = "Host port for JACK audio forwarding.";
    };
    
    diskImage = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Path to ArchibaldOS disk image.
        If using the archibaldos flake input, this will be set automatically.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    # ──────────────────────────────────────────────────────────────────────────
    # Kernel Parameters for CPU Isolation
    # ──────────────────────────────────────────────────────────────────────────
    boot.kernelParams = lib.mkAfter [
      # Isolate CPU core for DSP
      "isolcpus=${toString cfg.isolatedCpu}"
      "nohz_full=${toString cfg.isolatedCpu}"
      "rcu_nocbs=${toString cfg.isolatedCpu}"
      
      # IRQ affinity - exclude isolated core
      "irqaffinity=1-$(($(nproc) - 1))"
      "threadirqs"
      
      # Hugepages for QEMU
      "hugepagesz=2M"
      "hugepages=${toString cfg.hugepages}"
      
      # IOMMU for VFIO
      "amd_iommu=on"
      "iommu=pt"
    ];

    # ──────────────────────────────────────────────────────────────────────────
    # VFIO Kernel Modules
    # ──────────────────────────────────────────────────────────────────────────
    boot.kernelModules = [ 
      "vfio-pci" 
      "vfio_iommu_type1" 
      "vfio"
    ];
    
    boot.extraModprobeConfig = lib.mkIf (cfg.audioDevice.enable && cfg.audioDevice.vendorDevice != "") ''
      options vfio-pci ids=${cfg.audioDevice.vendorDevice}
      softdep snd_hda_intel pre: vfio-pci
    '';

    # ──────────────────────────────────────────────────────────────────────────
    # Libvirt for VM Management
    # ──────────────────────────────────────────────────────────────────────────
    virtualisation.libvirtd = {
      enable = true;
      qemu = {
        package = pkgs.qemu_kvm;
        runAsRoot = true;
        swtpm.enable = false;
        ovmf.enable = true;
      };
    };

    # ──────────────────────────────────────────────────────────────────────────
    # DSP VM Service
    # ──────────────────────────────────────────────────────────────────────────
    systemd.services.archibaldos-dsp-vm = {
      description = "ArchibaldOS DSP Coprocessor VM";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "libvirtd.service" ];
      requires = [ "libvirtd.service" ];
      
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = "5";
        
        # Run with real-time priority
        Nice = -20;
        IOSchedulingClass = "realtime";
        IOSchedulingPriority = 0;
        CPUSchedulingPolicy = "fifo";
        CPUSchedulingPriority = 99;
        
        # Pin to isolated CPU
        CPUAffinity = toString cfg.isolatedCpu;
        
        ExecStart = let
          # Build QEMU command
          baseCmd = ''
            ${pkgs.qemu_kvm}/bin/qemu-system-x86_64 \
              -enable-kvm \
              -name archibald-dsp,process=archibald-dsp \
              -m ${toString cfg.memoryMB} \
              -smp 1,sockets=1,cores=1,threads=1 \
              -cpu host,+topoext \
              -machine q35,accel=kvm,kernel_irqchip=on \
              -mem-prealloc \
              -mem-path /dev/hugepages \
              -realtime mlock=on
          '';
          
          diskOpts = lib.optionalString (cfg.diskImage != null) ''
              -drive file=${cfg.diskImage},format=raw,if=virtio,cache=unsafe,aio=native
          '';
          
          # VFIO passthrough for audio device
          vfioOpts = lib.optionalString cfg.audioDevice.enable ''
              -device vfio-pci,host=${cfg.audioDevice.pciId}
          '';
          
          # Network with JACK port forwarding
          netOpts = ''
              -netdev user,id=net0,hostfwd=tcp::${toString cfg.jackPort}-:4713 \
              -device virtio-net-pci,netdev=net0
          '';
          
          displayOpts = ''
              -nographic \
              -serial mon:stdio
          '';
          
        in pkgs.writeShellScript "start-archibald-dsp" ''
          exec ${baseCmd} \
            ${diskOpts} \
            ${vfioOpts} \
            ${netOpts} \
            ${displayOpts}
        '';
        
        ExecStop = "${pkgs.coreutils}/bin/kill -TERM $MAINPID";
      };

      # Crash protection
      startLimitIntervalSec = 300;
      startLimitBurst = 5;
    };

    # ──────────────────────────────────────────────────────────────────────────
    # Host-side JACK Bridge (optional)
    # ──────────────────────────────────────────────────────────────────────────
    systemd.services.dsp-jack-bridge = lib.mkIf cfg.audioDevice.enable {
      description = "JACK bridge to ArchibaldOS DSP VM";
      wantedBy = [ "multi-user.target" ];
      after = [ "archibaldos-dsp-vm.service" "pipewire.service" ];
      
      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = "10";
        User = "asher";
        
        ExecStart = pkgs.writeShellScript "dsp-jack-bridge" ''
          # Wait for VM to be ready
          sleep 10
          
          # Create netjack connection to VM
          exec ${pkgs.jack2}/bin/jack_netsource \
            -H 127.0.0.1 \
            -p ${toString cfg.jackPort} \
            -n dsp-vm \
            -C 2 -P 2 \
            -l 256 \
            -r 48000
        '';
      };
    };

    # ──────────────────────────────────────────────────────────────────────────
    # Firewall
    # ──────────────────────────────────────────────────────────────────────────
    networking.firewall.allowedTCPPorts = [ cfg.jackPort ];

    # ──────────────────────────────────────────────────────────────────────────
    # Helper Scripts
    # ──────────────────────────────────────────────────────────────────────────
    environment.systemPackages = [
      (pkgs.writeShellScriptBin "dsp-status" ''
        echo "=== ArchibaldOS DSP VM Status ==="
        systemctl status archibaldos-dsp-vm.service --no-pager
        echo ""
        echo "=== CPU Isolation ==="
        cat /sys/devices/system/cpu/isolated 2>/dev/null || echo "None"
        echo ""
        echo "=== Hugepages ==="
        cat /proc/meminfo | grep -i huge
      '')
      
      (pkgs.writeShellScriptBin "dsp-console" ''
        echo "Connecting to DSP VM console (Ctrl-A X to exit)..."
        ${pkgs.socat}/bin/socat -,raw,echo=0 UNIX-CONNECT:/run/archibald-dsp.sock 2>/dev/null || \
          echo "VM not running or console unavailable"
      '')
    ];

    # ──────────────────────────────────────────────────────────────────────────
    # Required Groups
    # ──────────────────────────────────────────────────────────────────────────
    users.users.asher.extraGroups = [ "libvirtd" "kvm" ];
  };
}

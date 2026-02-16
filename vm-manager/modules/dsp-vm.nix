{ config, pkgs, lib, ... }:

# ============================================================================
# DSP VM Module - ArchibaldOS DSP Coprocessor with NETJACK
# ============================================================================
# 
# This module creates an isolated VM running ArchibaldOS for real-time
# digital signal processing. It uses CPU isolation and NETJACK audio
# routing to the host PipeWire system.
#
# Prerequisites:
#   1. Build the VM image: nix build .#archibaldos-dsp-vm
#   2. Copy result to ~/vms/archibaldos-dsp.qcow2
#   3. Enable IOMMU in BIOS (AMD-Vi / Intel VT-d)
#
# ============================================================================

{
  options.custom.vm.dsp = {
    enable = lib.mkEnableOption "ArchibaldOS DSP coprocessor VM";
    
    name = lib.mkOption {
      type = lib.types.str;
      default = "archibaldos-dsp";
      description = "Name of the DSP VM.";
    };
    
    isolatedCores = lib.mkOption {
      type = lib.types.listOf lib.types.int;
      default = [ 0 ];
      description = "CPU cores to isolate for the DSP VM (e.g., [0,1] for cores 0-1).";
    };
    
    memoryMB = lib.mkOption {
      type = lib.types.int;
      default = 2048;
      description = "Memory allocation for the VM in MB.";
    };
    
    hugepages = lib.mkOption {
      type = lib.types.int;
      default = 1024;
      description = "Number of 2MB hugepages to reserve.";
    };
    
    cpuModel = lib.mkOption {
      type = lib.types.enum [ "host" "max" "EPYC" "Skylake-Server" ];
      default = "host";
      description = "CPU model for QEMU.";
    };
    
    archibaldOS = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Use ArchibaldOS as guest OS (recommended).";
      };
      
      diskImage = lib.mkOption {
        type = lib.types.path;
        default = ./config/archibaldos-dsp-image;
        description = "Path to pre-built ArchibaldOS disk image.";
      };
      
      netjack = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Enable NETJACK2 audio routing to host.";
        };
        
        sourcePort = lib.mkOption {
          type = lib.types.port;
          default = 4713;
          description = "Source port for NETJACK server in VM.";
        };
        
        bufferSize = lib.mkOption {
          type = lib.types.int;
          default = 128;
          description = "Buffer size in frames (128 @ 96kHz = 1.33ms).";
        };
        
        sampleRate = lib.mkOption {
          type = lib.types.int;
          default = 96000;
          description = "Sample rate in Hz (96000 for HD audio).";
        };
        
        channels = lib.mkOption {
          type = lib.types.int;
          default = 2;
          description = "Number of audio channels.";
        };
      };
    };
    
    audioDevice = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Enable VFIO passthrough of USB audio interface (alternative to NETJACK).";
      };
      
      pciId = lib.mkOption {
        type = lib.types.str;
        default = "0000:00:1b.0";
        description = "PCI address of audio device (from lspci -nn).";
      };
      
      vendorDevice = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "Vendor:Device ID for VFIO binding (e.g., '1022:15e3').";
      };
    };
    
    network = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable network for the VM.";
      };
      
      hostfwd = lib.mkOption {
        type = lib.types.attrsOf lib.types.int;
        default = { };
        description = "Port forwards in format { hostPort = guestPort; }.";
      };
    };
    
    qemuExtraArgs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Extra QEMU arguments.";
    };
    
    realtime = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Enable real-time scheduling and locking.";
      };
      
      mlock = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Lock memory (mlockall).";
      };
      
      nice = lib.mkOption {
        type = lib.types.int;
        default = -20;
        description = "Nice value (lower = higher priority).";
      };
    };
    
    spice = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable SPICE display for the VM.";
    };
    
    vnc = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable VNC display for the VM.";
    };
    
    tpm = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable TPM 2.0 emulation.";
    };
    
    ovmf = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable UEFI (OVMF).";
    };
  };

  config = let
    cfg = config.custom.vm.dsp;
  in lib.mkIf cfg.enable {
    boot.kernelParams = lib.mkAfter (
      let
        isolatedCoresStr = lib.concatStringsSep "," (map toString cfg.isolatedCores);
      in [
        "isolcpus=${isolatedCoresStr}"
        "nohz_full=${isolatedCoresStr}"
        "rcu_nocbs=${isolatedCoresStr}"
        "irqaffinity=1-$(($(nproc) - 1))"
        "threadirqs"
        "hugepagesz=2M"
        "hugepages=${toString cfg.hugepages}"
        "amd_iommu=on"
        "iommu=pt"
      ]
    );

    boot.kernelModules = [ 
      "vfio-pci" 
      "vfio_iommu_type1" 
      "vfio"
    ];
    
    boot.extraModprobeConfig = lib.mkIf (cfg.audioDevice.enable && cfg.audioDevice.vendorDevice != "") ''
      options vfio-pci ids=${cfg.audioDevice.vendorDevice}
      softdep snd_hda_intel pre: vfio-pci
    '';

    virtualisation.libvirtd = {
      enable = true;
      qemu = {
        package = pkgs.qemu_kvm;
        runAsRoot = true;
        swtpm.enable = cfg.tpm;
        ovmf.enable = cfg.ovmf;
      };
    };

    systemd.services.${cfg.name} = {
      description = "ArchibaldOS DSP Coprocessor VM";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "libvirtd.service" ];
      requires = [ "libvirtd.service" ];
      
      serviceConfig = {
        Type = "simple";
        Restart = "always";
        RestartSec = 5;
        
        Nice = cfg.realtime.nice;
        IOSchedulingClass = "realtime";
        IOSchedulingPriority = 0;
        CPUSchedulingPolicy = "fifo";
        CPUSchedulingPriority = 99;
        
        CPUAffinity = map toString cfg.isolatedCores;
        
        ExecStart = let
          coresCount = lib.length cfg.isolatedCores;
          coresStr = lib.concatStringsSep "," (map toString cfg.isolatedCores);
          
          baseCmd = ''
            ${pkgs.qemu_kvm}/bin/qemu-system-x86_64 \
              -enable-kvm \
              -name ${cfg.name},process=${cfg.name} \
              -m ${toString cfg.memoryMB} \
              -smp ${toString coresCount},sockets=1,cores=${toString coresCount},threads=1 \
              -cpu ${cfg.cpuModel},+topoext \
              -machine q35,accel=kvm,kernel_irqchip=on
          '';
          
          memoryOpts = lib.optionalString cfg.realtime.enable ''
              -mem-prealloc \
              -mem-path /dev/hugepages \
              ${lib.optionalString cfg.realtime.mlock "-realtime mlock=on"}
          '';
          
          # Use ArchibaldOS disk image path
          diskOpts = ''
              -drive file=${cfg.archibaldOS.diskImage},format=qcow2,if=virtio,cache=unsafe,aio=native
          '';
          
          vfioOpts = lib.optionalString cfg.audioDevice.enable ''
              -device vfio-pci,host=${cfg.audioDevice.pciId}
          '';
          
          # Network options - forward NETJACK port when enabled
          netOpts = let
            hostfwds = lib.mapAttrsToList (k: v: "hostfwd=tcp::${toString k}-:${toString v}") 
              (cfg.network.hostfwd // lib.optionalAttrs (cfg.archibaldOS.netjack.enable) {
                ${toString cfg.archibaldOS.netjack.sourcePort} = cfg.archibaldOS.netjack.sourcePort;
              });
          in lib.optionalString cfg.network.enable ''
              -netdev user,id=net0,${lib.concatStringsSep "," hostfwds} \
              -device virtio-net-pci,netdev=net0
          '';
          
          displayOpts = 
            lib.optionalString cfg.spice " -vga virtio -display gtk,gl=on"
            ++ lib.optionalString cfg.vnc " -vnc :0"
            ++ lib.optionalString (!cfg.spice && !cfg.vnc) " -nographic -serial mon:stdio";
          
          tpmOpts = lib.optionalString cfg.tpm ''
              -tpmdev emulator,id=tpm0,tpm-type=tpm2-emulator \
              -device tpm-tis,tpmdev=tpm0
          '';
          
        in pkgs.writeShellScript "start-${cfg.name}" ''
          exec ${baseCmd} ${memoryOpts} ${diskOpts} ${vfioOpts} ${netOpts} ${displayOpts} ${tpmOpts} ${lib.concatStringsSep " " cfg.qemuExtraArgs}
        '';
        
        ExecStop = "${pkgs.coreutils}/bin/kill -TERM $MAINPID";
      };

      startLimitIntervalSec = 300;
      startLimitBurst = 5;
    };

    # NETJACK bridge service - connects to VM's JACK server
    systemd.services.dsp-netjack-bridge = lib.mkIf cfg.archibaldOS.netjack.enable {
      description = "NETJACK bridge to ArchibaldOS DSP VM";
      wantedBy = [ "multi-user.target" ];
      after = [ "${cfg.name}.service" "pipewire.service" ];
      requires = [ "${cfg.name}.service" ];
      
      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = 10;
        User = "asher";
        
        ExecStart = pkgs.writeShellScript "dsp-netjack-bridge" ''
          # Wait for VM to boot and JACK to start
          sleep 15
          
          # Connect to VM's NETJACK server
          # 128 frames @ 96kHz = 1.33ms round-trip latency
          exec ${pkgs.jack2}/bin/jack_netsource \
            -H 10.0.2.2 \
            -p ${toString cfg.archibaldOS.netjack.sourcePort} \
            -n archibaldos-dsp \
            -C ${toString cfg.archibaldOS.netjack.channels} \
            -P ${toString cfg.archibaldOS.netjack.channels} \
            -l ${toString cfg.archibaldOS.netjack.bufferSize} \
            -r ${toString cfg.archibaldOS.netjack.sampleRate}
        '';
        
        ExecStop = "${pkgs.coreutils}/bin/kill -TERM $MAINPID";
      };
    };

    # Legacy JACK bridge for VFIO audio device passthrough
    systemd.services.dsp-jack-bridge = lib.mkIf cfg.audioDevice.enable {
      description = "JACK bridge to DSP VM (VFIO passthrough)";
      wantedBy = [ "multi-user.target" ];
      after = [ "${cfg.name}.service" "pipewire.service" ];
      
      serviceConfig = {
        Type = "simple";
        Restart = "on-failure";
        RestartSec = 10;
        User = "asher";
        
        ExecStart = pkgs.writeShellScript "dsp-jack-bridge" ''
          sleep 10
          exec ${pkgs.jack2}/bin/jack_netsource \
            -H 127.0.0.1 \
            -p 4713 \
            -n dsp-vm \
            -C 2 -P 2 \
            -l 256 \
            -r 48000
        '';
      };
    };

    networking.firewall.allowedTCPPorts = lib.mkIf cfg.network.enable 
      (lib.attrValues cfg.network.hostfwd ++ lib.optionals cfg.archibaldOS.netjack.enable [ cfg.archibaldOS.netjack.sourcePort ]);

    environment.systemPackages = [
      (pkgs.writeShellScriptBin "dsp-status" ''
        echo "=== DSP VM Status ==="
        systemctl status ${cfg.name}.service --no-pager || true
        echo ""
        echo "=== CPU Isolation ==="
        cat /sys/devices/system/cpu/isolated 2>/dev/null || echo "None"
        echo ""
        echo "=== Hugepages ==="
        cat /proc/meminfo | grep -i huge
        echo ""
        echo "=== NETJACK Bridge ==="
        systemctl status dsp-netjack-bridge.service --no-pager || true
      '')
      
      (pkgs.writeShellScriptBin "dsp-console" ''
        echo "Connecting to DSP VM console (Ctrl-A X to exit)..."
        ${pkgs.socat}/bin/socat -,raw,echo=0 UNIX-CONNECT:/run/${cfg.name}.sock 2>/dev/null || \
          echo "VM not running or console unavailable"
      '')
      
      (pkgs.writeShellScriptBin "dsp-netjack-restart" ''
        echo "Restarting NETJACK bridge..."
        systemctl restart dsp-netjack-bridge.service
      '')
    ];

    users.users.asher.extraGroups = [ "libvirtd" "kvm" "audio" ];
  };
}

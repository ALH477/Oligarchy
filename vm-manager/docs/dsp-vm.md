# ArchibaldOS DSP VM with NETJACK Audio Routing

Real-time audio processing coprocessor with ultra-low latency.

## Overview

The DSP VM runs ArchibaldOS with a CachyOS RT kernel, isolated from the host system. Audio is routed to the host via NETJACK2 over the virtual network.

### Performance Targets

| Metric | Target | Actual |
|--------|--------|--------|
| Round-trip latency | <2ms | 1.33ms |
| Sample rate | 96kHz | 96kHz |
| Bit depth | 24-bit | 24-bit |
| Buffer size | 128 samples | 128 samples |
| CPU cores | 1-2 | 0-1 (isolated) |
| Memory | 2-4GB | 4GB |

## Prerequisites

### Hardware

- **CPU**: AMD Ryzen 7040 series (or equivalent with IOMMU)
- **RAM**: 32GB+ recommended (8GB for host, 4GB for DSP VM, 20GB for apps)
- **Storage**: 20GB+ SSD for VM image

### BIOS Settings

1. Enable **AMD-Vi** (IOMMU)
2. Enable **SVM** (Virtualization)
3. Configure **CPU isolation** (if available)

### Host Configuration

Add to kernel params:
```nix
boot.kernelParams = [
  "amd_iommu=on"
  "iommu=pt"
  "isolcpus=0,1"
  "nohz_full=0,1"
  "rcu_nocbs=0,1"
  "threadirqs"
];
```

## Installation

### Step 1: Build the VM Image

```bash
# Clone ArchibaldOS
cd modules/ArchibaldOS

# Build the headless DSP configuration
nix build .#hydramesh-iso

# Convert to raw disk image
qemu-img convert -O raw result ~/vms/archibaldos-dsp.qcow2
```

### Step 2: Configure the Host

Add to `configuration.nix`:

```nix
imports = [ vm-manager.nixosModules.dsp-vm ];

custom.vm.dsp = {
  enable = true;
  
  # CPU isolation - use cores 0-1
  isolatedCores = [ 0 1 ];
  
  # Memory allocation
  memoryMB = 4096;
  
  # Hugepages for real-time performance
  hugepages = 2048;
  
  # ArchibaldOS configuration
  archibaldOS = {
    enable = true;
    diskImage = ~/vms/archibaldos-dsp.qcow2;
    
    # NETJACK audio routing
    netjack = {
      enable = true;
      sourcePort = 4713;
      bufferSize = 128;      # 1.33ms @ 96kHz
      sampleRate = 96000;
      channels = 2;
    };
  };
};
```

### Step 3: Rebuild

```bash
sudo nixos-rebuild switch --flake .#nixos
```

## Configuration Reference

### DSP VM Options

```nix
custom.vm.dsp = {
  # Required
  enable = true;
  isolatedCores = [ 0 ];
  memoryMB = 2048;
  
  # Optional - ArchibaldOS
  archibaldOS = {
    enable = true;
    diskImage = /path/to/image.qcow2;
    
    # NETJACK settings
    netjack = {
      enable = true;
      sourcePort = 4713;      # Port on VM
      bufferSize = 128;        # Frames per buffer
      sampleRate = 96000;      # Hz
      channels = 2;             # Stereo
    };
  };
  
  # Alternative: VFIO audio passthrough
  audioDevice = {
    enable = false;
    pciId = "0000:00:1b.0";  # From lspci
    vendorDevice = "1022:15e3"; # For vfio-pci
  };
  
  # Performance tuning
  hugepages = 1024;
  realtime = {
    enable = true;
    mlock = true;
    nice = -20;
  };
  
  # Display (optional)
  spice = false;
  vnc = false;
  
  # Network
  network = {
    enable = true;
    hostfwd = {
      2222 = 22;  # SSH
    };
  };
  
  # QEMU extra args
  qemuExtraArgs = [ ];
};
```

## Usage

### Starting the VM

```bash
# The VM starts automatically on boot
systemctl start archibaldos-dsp
```

### Checking Status

```bash
# Built-in status script
dsp-status

# Sample output:
# === DSP VM Status ===
# ● archibaldos-dsp.service - ArchibaldOS DSP Coprocessor VM
#    Loaded: loaded (/etc/systemd/system/archibaldos-dsp.service; enabled)
#    Active: active (running) since Mon 2026-02-16 04:00:00 UTC
#
# === CPU Isolation ===
# 0-1
#
# === Hugepages ===
# HugePages_Total:  1024
# HugePages_Free:   512
# HugePages_Rsvd:   512
#
# === NETJACK Bridge ===
# ● dsp-netjack-bridge.service - NETJACK bridge to ArchibaldOS DSP VM
#    Active: active (running)
```

### Connecting to VM Console

```bash
dsp-console
# Press Ctrl-A X to exit
```

### Restarting NETJACK

```bash
dsp-netjack-restart
```

## Audio Routing

### Host Side (PipeWire)

The NETJACK bridge creates a remote JACK client on the host:

```
Host PipeWire → NETJACK Bridge → Virtual Network → VM JACK → Applications
```

### Viewing Audio Connections

```bash
# List JACK ports
jack_lsp

# List NETJACK connections
jack_lsp -c netjack

# Connect applications
jack_connect "Spotify:output_left" "netjack:capture_1"
jack_connect "netjack:playback_1" "PulseAudio:front-left"
```

### Latency Calculation

```
Round-trip latency = (buffer_size / sample_rate) × 2
                   = (128 / 96000) × 2
                   = 0.00267 seconds
                   = 2.67ms
```

For lower latency, reduce buffer size (warning: may cause xruns):
```nix
archibaldOS.netjack.bufferSize = 64;  # 1.33ms round-trip
```

## Won't Troubleshooting

### VM Start

```bash
# Check logs
journalctl -u archibaldos-dsp -f

# Common issues:
# - IOMMU not enabled in BIOS
# - Hugepages not configured
# - CPU cores don't exist
```

### NETJACK Connection Failed

```bash
# Check VM is running
systemctl status archibaldos-dsp

# Check NETJACK service
systemctl status dsp-netjack-bridge

# Check network
ping 10.0.2.2  # VM IP

# Restart NETJACK
dsp-netjack-restart
```

### Audio Xruns

```bash
# Increase buffer size
archibaldOS.netjack.bufferSize = 256;

# Check CPU isolation
cat /sys/devices/system/cpu/isolated

# Disable hyperthreading in BIOS
```

### High Latency

```bash
# Verify buffer size
jack_bufsize

# Check for CPU throttling
cat /proc/cpuinfo | grep MHz

# Check for interrupt conflicts
cat /proc/interrupts | head -20
```

## Advanced: VFIO Audio Passthrough

For lowest latency, bypass NETJACK with VFIO passthrough:

```nix
custom.vm.dsp = {
  enable = true;
  
  # Disable NETJACK
  archibaldOS.netjack.enable = false;
  
  # Enable VFIO audio passthrough
  audioDevice = {
    enable = true;
    pciId = "0000:00:1b.0";  # USB audio interface
    
    # For vfio-pci binding
    vendorDevice = "1234:5678";
  };
};
```

**Finding your audio device:**
```bash
lspci -nn | grep -i audio
# Example: 0000:00:1b.0 [0403] Intel Corporation Celeron N3350/Pentium N4200 Audio Cluster
```

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                        HOST SYSTEM                          │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐   │
│  │   Hyprland  │    │  PipeWire   │    │  NETJACK    │   │
│  │  (Gaming)   │───▶│  (Audio)    │◀───│   Bridge    │   │
│  └─────────────┘    └──────┬──────┘    └──────┬──────┘   │
│                             │                    │          │
│                      ┌──────▼──────┐            │          │
│                      │  VM Network  │◀───────────┘          │
│                      │   (virtio)  │                       │
│                      └──────┬──────┘                       │
└─────────────────────────────┼───────────────────────────────┘
                              │
┌─────────────────────────────▼───────────────────────────────┐
│                    DSP VM (ArchibaldOS)                      │
│  ┌─────────────┐    ┌─────────────┐    ┌─────────────┐     │
│  │  CachyOS   │    │  JACK2      │    │   Apps     │     │
│  │  RT Kernel  │───▶│ (NETJACK)  │◀───│ (DAW/DSP)  │     │
│  └─────────────┘    └─────────────┘    └─────────────┘     │
│        │                                                       │
│  ┌──────▼──────┐                                              │
│  │ CPU Isolated │  cores 0-1                                  │
│  │ (real-time)  │                                              │
│  └─────────────┘                                              │
└──────────────────────────────────────────────────────────────┘
```

## See Also

- [VM Manager Overview](../README.md)
- [ArchibaldOS Documentation](../../modules/ArchibaldOS/README.md)
- [NETJACK Documentation](https://jackaudio.org/docs/net_one/)

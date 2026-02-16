# VM Manager - Hybrid Low-Overhead VM Management

Production-ready virtual machine management for Oligarchy NixOS with optimized resource allocation and hardware passthrough.

## Overview

The VM Manager provides a declarative way to configure and run multiple virtual machines with specific hardware isolation requirements:

| VM | Purpose | CPU Cores | RAM | Storage | Network |
|----|---------|-----------|-----|---------|---------|
| **DSP Coprocessor** | Real-time audio processing | 0-1 | 2-4GB | 20GB+ | NETJACK |
| **Coding Sandbox** | Headless development | Last-1 | 2-4GB | 64GB | NAT |
| **Kali Linux** | Security/hacking | Last | 4GB | 80GB | NAT/Bridge |
| **OpenWRT Router** | Network routing | 1 | 512MB | 512MB | Bridged |

## Quick Start

### Enable a VM

Add to your `configuration.nix`:

```nix
imports = [ vm-manager.nixosModules.dsp-vm ];

# DSP VM with ArchibaldOS and NETJACK
custom.vm.dsp = {
  enable = true;
  isolatedCores = [ 0 1 ];
  memoryMB = 4096;
  archibaldOS = {
    enable = true;
    netjack.enable = true;
  };
};
```

### Using Pre-built Configs

```nix
imports = [
  vm-manager.nixosModules.coding-sandbox
  vm-manager.nixosModules.kali-linux
  vm-manager.nixosModules.openwrt-router
];
```

## VM Types

### DSP Coprocessor (ArchibaldOS + NETJACK)

Real-time audio processing with ultra-low latency.

```nix
custom.vm.dsp = {
  enable = true;
  isolatedCores = [ 0 1 ];
  memoryMB = 4096;
  hugepages = 2048;
  
  archibaldOS = {
    enable = true;
    diskImage = ~/vms/archibaldos-dsp.qcow2;
    netjack = {
      enable = true;
      sourcePort = 4713;
      bufferSize = 128;      # 1.33ms @ 96kHz
      sampleRate = 96000;     # HD audio
      channels = 2;
    };
  };
};
```

**Features:**
- CachyOS RT kernel with BORE scheduler
- CPU isolation (isolcpus, nohz_full, rcu_nocbs)
- NETJACK2 audio routing to host PipeWire
- 128 samples @ 96kHz = 1.33ms latency
- VFIO passthrough for USB audio devices

**Helper Commands:**
```bash
dsp-status        # Check VM and NETJACK status
dsp-console      # Connect to VM console
dsp-netjack-restart  # Restart NETJACK bridge
```

### Coding Sandbox

Headless Arch Linux VM for coding agents.

```nix
custom.vm.quickemu = {
  enable = true;
  name = "coding-sandbox";
  cores = 1;
  memory = 3072;
  diskSize = "64G";
  ssh = true;
  portForwards = [ "2222:22" ];
};
```

### Kali Linux

Security and penetration testing VM.

```nix
custom.vm.quickemu = {
  enable = true;
  name = "kali-linux";
  cores = 1;
  memory = 4096;
  diskSize = "80G";
  spice = true;
  ssh = true;
};
```

### OpenWRT Router

Lightweight router VM.

```nix
custom.vm.quickemu = {
  enable = true;
  name = "openwrt-router";
  cores = 1;
  memory = 512;
  diskSize = "512M";
  os = "openwrt";
  network = {
    type = "bridge";
    bridge = "br0";
  };
  # pciDevice = "0000:03:00.0";  # NIC passthrough
};
```

## Configuration Options

### Quickemu VM Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | false | Enable the VM |
| `name` | string | "quickemu-vm" | VM name |
| `cores` | int | 1 | CPU cores |
| `memory` | int | 2048 | RAM in MB |
| `diskSize` | string | "32G" | Disk size |
| `os` | enum | "arch" | OS: arch, debian, fedora, kali, ubuntu, openwrt |
| `network.type` | enum | "nat" | Network: nat, bridge, host |
| `network.bridge` | string | null | Bridge interface (e.g., br0) |
| `pciDevice` | string | null | PCI device for passthrough |
| `usbDevice` | string | null | USB device for passthrough |
| `portForwards` | list | [] | Port forwards (host:guest) |
| `spice` | bool | false | Enable SPICE display |
| `vnc` | bool | false | Enable VNC display |
| `ssh` | bool | false | Enable SSH port forward |

### DSP VM Options

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | false | Enable the DSP VM |
| `isolatedCores` | list | [0] | CPU cores to isolate |
| `memoryMB` | int | 2048 | RAM in MB |
| `hugepages` | int | 1024 | 2MB hugepages |
| `archibaldOS.enable` | bool | true | Use ArchibaldOS |
| `archibaldOS.netjack.enable` | bool | true | Enable NETJACK |
| `archibaldOS.netjack.bufferSize` | int | 128 | Buffer frames |
| `archibaldOS.netjack.sampleRate` | int | 96000 | Sample rate Hz |
| `audioDevice.enable` | bool | false | VFIO audio passthrough |

## Building VM Images

### ArchibaldOS DSP VM

The DSP VM requires building from the ArchibaldOS flake:

```bash
# From ArchibaldOS directory
cd modules/ArchibaldOS
nix build .#hydramesh-iso
qemu-img convert -O raw result ~/vms/archibaldos-dsp.qcow2
```

### OpenWRT Router

```bash
mkdir -p ~/vms
cd ~/vms
wget https://downloads.openwrt.org/releases/24.10.5/targets/x86/generic/openwrt-24.10.5-x86-generic-generic-ext4-combined.img.gz
gunzip openwrt-24.10.5-x86-generic-generic-ext4-combined.img.gz
qemu-img convert -O qcow2 openwrt-24.10.5-x86-generic-generic-ext4-combined.img openwrt-router.qcow2
```

## Network Configuration

### Bridged Networking

For VMs that need direct network access:

```nix
network = {
  type = "bridge";
  bridge = "br0";
};
```

**Prerequisites:**
1. Create bridge on host: `ip link add br0 type bridge`
2. Add physical interface: `ip link set eth0 master br0`
3. Configure in `/etc/nixos/configuration.nix`

### PCI Passthrough

For hardware passthrough (requires IOMMU):

```nix
# Find PCI device
lspci -nn | grep -i network

# Add to VM config
pciDevice = "0000:03:00.0";
```

Enable IOMMU in BIOS and add to kernel params:
```nix
boot.kernelParams = [ "amd_iommu=on" "iommu=pt" ];
```

## Troubleshooting

### DSP VM

```bash
# Check VM status
dsp-status

# View VM logs
journalctl -u archibaldos-dsp -f

# Check CPU isolation
cat /sys/devices/system/cpu/isolated

# Check hugepages
cat /proc/meminfo | grep Huge

# Test NETJACK connection
jack_lsp -c netjack
```

### Quickemu VMs

```bash
# Check VM status
systemctl status quickemu-vm

# View logs
journalctl -u quickemu-vm -f

# Start manually
quickemu --vm /var/lib/quickemu/vm-name/vm-name.conf
```

## Module Structure

```
vm-manager/
├── flake.nix              # Flake entry point
├── modules/
│   ├── dsp-vm.nix        # DSP VM with ArchibaldOS
│   ├── quickemu-vm.nix   # General Quickemu VM
│   └── archibaldos-dsp-audio.nix  # DSP audio config
└── config/
    ├── archibaldos-dsp.nix   # ArchibaldOS DSP config
    ├── sandbox.nix        # Coding sandbox
    ├── kali.nix           # Kali Linux
    └── openwrt-router.nix # OpenWRT router
```

## See Also

- [DSP VM with NETJACK](./docs/dsp-vm.md)
- [OpenWRT Router Setup](./docs/openwrt-router.md)
- [ArchibaldOS Documentation](../modules/ArchibaldOS/README.md)
- [DeMoD Voice](../modules/demod-voice/README.md)

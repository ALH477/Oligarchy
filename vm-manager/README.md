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

### 1. Build the Guest Image

The guest is defined in-tree (`modules/dsp-guest.nix`, a plain NixOS
config: `linuxPackages_xanmod_latest`, not PREEMPT_RT — that kernel and
CachyOS RT were both removed from nixpkgs) and built as a reproducible,
UEFI-bootable `qcow-efi` image by the top-level flake:

```bash
nix build .#dsp-vm-qcow
```

On `nixosConfigurations.nixos` the resulting derivation is already wired
into `custom.vm.dsp.archibaldOS.diskImage` (see `flake.nix`), so there is
nothing to copy anywhere — the store path *is* the disk image, booted
through a writable qcow2 overlay under `/var/lib/qemu` (see `overlay`
below). There is no external `ArchibaldOS` repo to clone for this; the
`modules/ArchibaldOS/` sub-flake in this tree is an unrelated desktop/ISO
project and is not wired to the DSP guest at all.

### 2. Configure Hardware-Specific Settings

Before deploying, you need to identify your hardware:

```bash
# Find USB audio controllers (for VFIO passthrough)
lspci -nn | grep -i "USB.*controller"

# Find available CPU cores
lscpu | grep "CPU(s):"

# Check IOMMU groups (for VFIO)
ls -l /sys/kernel/iommu_groups/*/devices/
```

### 3. Deploy the Host Configuration

`configuration.nix` on the `nixos` host already carries the DSP VM's
hardware-specific settings (cores, hugepages, VFIO ids) with
`custom.vm.dsp.enable = lib.mkDefault false;` — flip it to `true` (in
`~/.config/oligarchy/local.nix` if you keep personal toggles out of the
repo; that path needs `--impure` to be seen, see `CLAUDE.md`), then:

```bash
sudo nixos-rebuild switch --flake .#nixos --impure
```

`autoStart` defaults to **false**, on purpose: starting the VM binds the
passed-through USB (xHCI) controller to `vfio-pci` and hands it to the
guest, so every audio interface on that controller disappears from the
host mid-session. Start it deliberately once you're ready:

```bash
sudo systemctl start archibaldos-dsp
```

## Hardware Configuration

The DSP VM requires hardware-specific configuration. All settings are NixOS module options that can be customized in `configuration.nix`.

### CPU Isolation

Isolate CPU cores for deterministic RT processing. Choose cores that won't be used by the host.

```nix
custom.vm.dsp = {
  isolatedCores = [ 0 1 ];  # Isolate cores 0 and 1
};
```

**Finding your cores:**
```bash
# See all CPU cores
lscpu | grep "CPU(s):"

# Check current isolation
cat /sys/devices/system/cpu/isolated

# Recommended: use the first 2 cores for the DSP VM
# Adjust based on your CPU topology
```

### Memory Allocation

```nix
custom.vm.dsp = {
  memoryMB = 2048;   # 2GB RAM for the VM
  hugepages = 2048;  # 2048 × 2MB = 4GB hugepages (2x VM memory for safety)
};
```

**Guidelines:**
- `memoryMB`: VM RAM (2048MB minimum for JACK2 + PipeWire + musnix)
- `hugepages`: Should be ≥ `memoryMB / 2` (each hugepage is 2MB)

### VFIO Audio Passthrough

Pass USB audio controllers directly to the VM for zero-latency hardware access.

```nix
custom.vm.dsp = {
  audioDevice = {
    enable = true;
    usbController = {
      enable = true;
      xhciUsb2PciId = "0000:c7:00.3";      # Your USB2 controller
      xhciUsb3PciId = "0000:c7:00.4";      # Your USB3 companion
      usb2VendorDevice = "1022:15C0";       # From lspci -nn
      usb3VendorDevice = "1022:15C1";       # From lspci -nn
    };
  };
};
```

**Finding your PCI IDs:**
```bash
# List all USB controllers with vendor:device IDs
lspci -nn | grep -i "USB.*controller"

# Example output:
# c7:00.3 USB controller [0c03]: Advanced Micro Devices, Inc. [AMD] Device [1022:15c0]
# c7:00.4 USB controller [0c03]: Advanced Micro Devices, Inc. [AMD] Device [1022:15c1]

# Extract the PCI address (c7:00.3) and vendor:device (1022:15c0)
```

**IOMMU requirements:**
- Enable AMD-Vi or Intel VT-d in BIOS
- Add to kernel params:
  ```nix
  boot.kernelParams = [
    "amd_iommu=on"  # or "intel_iommu=on" for Intel
    "iommu=pt"
  ];
  ```

### Disk Image Path

```nix
custom.vm.dsp = {
  archibaldOS = {
    diskImage = self.packages.x86_64-linux.dsp-vm-qcow;  # reproducible, GC-rooted
  };
};
```

A bare path string is still accepted for a hand-managed image (the
option type is `path` or `str`), but only the derivation form is rebuilt
by `nix build .#dsp-vm-qcow` — a plain path under `/home` is not produced
by anything in this repo. Either way `diskImage` is booted read-only
through a writable qcow2 overlay under `/var/lib/qemu` (`archibaldOS.overlay`,
default `true`); delete the overlay file to reset the guest to a clean
image.

### NETJACK Audio Settings

```nix
custom.vm.dsp = {
  archibaldOS = {
    netjack = {
      enable = true;
      sourcePort = 4713;      # Port for NETJACK routing
      bufferSize = 32;        # 32 samples @ 96kHz = 0.33ms
      sampleRate = 96000;     # 96kHz HD audio
      channels = 2;           # Stereo
    };
  };
};
```

**Latency calculation:**
```
Buffer latency = bufferSize / sampleRate
               = 32 / 96000
               = 0.000333 seconds
               = 0.33ms

Round-trip (with n=2 buffers) = 0.67ms
```

### Complete Example

```nix
imports = [ vm-manager.nixosModules.dsp-vm ];

custom.vm.dsp = {
  enable = true;
  
  # Hardware-specific (adjust for your system)
  isolatedCores = [ 0 1 ];
  memoryMB = 2048;
  hugepages = 2048;
  
  # VFIO passthrough (adjust PCI IDs for your hardware)
  audioDevice = {
    enable = true;
    usbController = {
      enable = true;
      xhciUsb2PciId = "0000:c7:00.3";
      xhciUsb3PciId = "0000:c7:00.4";
      usb2VendorDevice = "1022:15C0";
      usb3VendorDevice = "1022:15C1";
    };
  };
  
  # Guest image
  archibaldOS = {
    enable = true;
    diskImage = self.packages.x86_64-linux.dsp-vm-qcow;  # from `nix build .#dsp-vm-qcow`
    
    netjack = {
      enable = true;
      sourcePort = 4713;
      bufferSize = 32;
      sampleRate = 96000;
      channels = 2;
    };
  };
};
```

## Using Pre-built Configs

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
    diskImage = self.packages.x86_64-linux.dsp-vm-qcow;
    netjack = {
      enable = true;
      sourcePort = 4713;
      bufferSize = 128;      # 128/96000 = 1.33ms buffer period
      sampleRate = 96000;     # HD audio
      channels = 2;
    };
  };
};
```

**Features:**
- XanMod kernel (`linuxPackages_xanmod_latest`), carrying the RT patch
  set — PREEMPT_RT and CachyOS RT were both removed from nixpkgs, so
  neither is available; see `modules/dsp-guest.nix`
- CPU isolation (isolcpus, nohz_full, rcu_nocbs)
- NETJACK2 audio routing to host PipeWire
- Buffer math above is arithmetic, not a measured round trip — no
  latency has been re-measured against the XanMod guest yet (the old
  CachyOS-RT figures no longer apply); see `docs/architecture.md` §10
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

### DSP VM guest

Built straight from this repo's top-level flake — no separate clone,
and no conversion step:

```bash
nix build .#dsp-vm-qcow
```

The format is `qcow-efi` (a real ESP for the OVMF firmware the host
runner supplies) — converting to a raw/BIOS image here would reproduce
the exact failure this guest used to have: OVMF finds no EFI entry,
falls through to a PXE netboot loop, and the isolated cores spin at
100% forever. `modules/ArchibaldOS/` is a separate, unrelated sub-flake
(a desktop/ISO project) and building it does not produce this guest.

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
├── flake.nix              # Flake entry point — exposes nixosModules
│                          # dsp-vm, quickemu-vm, coding-sandbox,
│                          # kali-linux, openwrt-router
├── modules/
│   ├── dsp-vm.nix        # THE live DSP VM module (custom.vm.dsp)
│   ├── quickemu-vm.nix   # General Quickemu VM
│   └── archibaldos-dsp-audio.nix  # dead: only imported by
│                          # config/archibaldos-dsp.nix below, which
│                          # is itself exposed by no nixosModule and
│                          # imported nowhere in this repo
└── config/
    ├── archibaldos-dsp.nix   # dead, see above — not `dsp-vm.nix`
    ├── sandbox.nix        # Coding sandbox
    ├── kali.nix           # Kali Linux
    └── openwrt-router.nix # OpenWRT router
```

The guest OS itself (what actually boots inside the VM `dsp-vm.nix`
launches) is defined outside this sub-flake entirely, at the top level:
`modules/dsp-guest.nix`, built by `nix build .#dsp-vm-qcow`.

## See Also

- [DSP VM with NETJACK](./docs/dsp-vm.md)
- [OpenWRT Router Setup](./docs/openwrt-router.md)
- [DSP guest OS (in-tree, what actually boots)](../modules/dsp-guest.nix)
- `../modules/ArchibaldOS/README.md` is a separate, unrelated
  desktop/ISO sub-flake — not the DSP guest, despite its own README
  claiming otherwise
- [DeMoD Voice](../modules/demod-voice/README.md)

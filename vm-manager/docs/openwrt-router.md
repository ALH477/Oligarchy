# OpenWRT Router VM

Lightweight router VM running OpenWRT for network routing, firewall, and VPN services.

## Overview

| Resource | Value |
|----------|-------|
| CPU Cores | 1 |
| RAM | 512MB |
| Storage | 512MB |
| Network | Bridged + optional NIC passthrough |

## Prerequisites

### Bridge Network Setup

On the host, create a network bridge:

```bash
# Create bridge interface
sudo ip link add br0 type bridge

# Add your physical interface
sudo ip link set eth0 master br0

# Configure IP (if using as primary router)
sudo ip addr add 192.168.1.1/24 dev br0
sudo ip link set br0 up
```

To persist across reboots, add to `configuration.nix`:

```nix
networking.bridges = {
  br0 = {
    interfaces = [ "eth0" ];
  };
};

networking.interfaces.br0 = {
  ipv4.addresses = [
    { address = "192.168.1.1"; prefixLength = 24; }
  ];
};
```

### IOMMU for NIC Passthrough

If using NIC passthrough, enable IOMMU:

```nix
boot.kernelParams = [
  "amd_iommu=on"
  "iommu=pt"
];
```

Find your NIC PCI address:
```bash
lspci -nn | grep -i ethernet
# Example: 0000:03:00.0 Realtek Semiconductor Co., Ltd. RTL8125
```

## Installation

### Step 1: Download OpenWRT

```bash
mkdir -p ~/vms
cd ~/vms

# Download x86 generic image
wget https://downloads.openwrt.org/releases/24.10.5/targets/x86/generic/openwrt-24.10.5-x86-generic-generic-ext4-combined.img.gz

# Verify checksum
echo "5979270b2ff86d2b3bd908bf8dcdb7efe4c1cf0f7525cc1d99227d38b913fb1e  openwrt-24.10.5-x86-generic-generic-ext4-combined.img.gz" | sha256sum -c

# Decompress
gunzip openwrt-24.10.5-x86-generic-generic-ext4-combined.img.gz

# Convert to QCOW2
qemu-img convert -O qcow2 \
  openwrt-24.10.5-x86-generic-generic-ext4-combined.img \
  openwrt-router.qcow2
```

### Step 2: Configure the Host

```nix
imports = [ vm-manager.nixosModules.quickemu-vm ];

custom.vm.quickemu = {
  enable = true;
  name = "openwrt-router";
  
  # Minimal resources
  cores = 1;
  memory = 512;
  diskSize = "512M";
  
  # OpenWRT
  os = "openwrt";
  diskImage = ~/vms/openwrt-router.qcow2;
  
  # Bridged networking
  network = {
    type = "bridge";
    bridge = "br0";
  };
  
  # Optional: NIC passthrough
  # pciDevice = "0000:03:00.0";
  
  # Headless
  spice = false;
  vnc = false;
};
```

### Step 3: Rebuild

```bash
sudo nixos-rebuild switch --flake .#nixos
```

## Configuration

### Default OpenWRT Access

After first boot, access via:

```bash
# Serial console
dsp-console  # or use openwrt-console

# Via network (if bridged)
ssh root@192.168.1.1
```

Default credentials: No password (root)

### Initial Setup

```bash
# Set root password
passwd

# Configure network
# Option 1: As gateway
uci set network.lan.ipaddr='192.168.1.1'
uci set network.lan.gateway='ISP_GATEWAY'
uci set network.lan.dns='1.1.1.1'

# Option 2: As NAT router
uci set network.wan=interface
uci set network.wan.device='eth0'
uci set network.wan.proto='dhcp'

# Save and apply
uci commit
/etc/init.d/network restart
```

### Common Configurations

#### As Primary Router

```bash
# LAN: 192.168.1.0/24
# WAN: DHCP from ISP

uci set network.lan.ipaddr='192.168.1.1'
uci set network.lan.proto='static'

uci set network.wan=interface
uci set network.wan.device='eth0'
uci set network.wan.proto='dhcp'

# Enable DHCP on LAN
uci set dhcp.lan=dhcp
uci set dhcp.lan.interface='lan'
uci set dhcp.lan.start='100'
uci set dhcp.lan.limit='150'
uci set dhcp.lan.leasetime='12h'

# Enable firewall
uci set firewall.defaults=defaults
uci set firewall.defaults.input='ACCEPT'
uci set firewall.defaults.output='ACCEPT'
uci set firewall.defaults.forward='REJECT'

uci commit
/etc/init.d/network restart
/etc/init.d/dnsmasq restart
/etc/init.d/firewall restart
```

#### With WiFi

```bash
# Install WiFi packages (in VM)
opkg update
opkg install hostapd wpa-supplicant

# Configure WiFi
uci set network.wifi=interface
uci set network.wifi.device='wlan0'
uci set network.wifi.mode='ap'
uci set network.wifi.ssid='MyNetwork'
uci set network.wifi.encryption='psk2'
uci set network.wifi.key='password'

uci commit
/etc/init.d/network restart
```

#### With VPN

```bash
# Install OpenVPN or WireGuard
opkg install wireguard-tools

# Configure WireGuard
uci set network.wg0=interface
uci set network.wg0.proto='wireguard'
uci set network.wg0.privatekey='YOUR_PRIVATE_KEY'
uci add_list network.wg0 addresses='10.0.0.2/24'

# Add peer
uci set network.wgpeer=wireguard_wg0
uci set network.wgpeer.publickey='PEER_PUBLIC_KEY'
uci add_list network.wgpeer allowedips='0.0.0.0/0'
uci set network.wgpeer.endpoint_host='vpn.example.com'

uci commit
/etc/init.d/network restart
```

## Network Options

### Bridged Networking (Default)

The VM connects to the host bridge:

```
┌─────────────┐       ┌─────────────┐
│   Internet  │──────▶│    Host      │
│             │       │   (br0)      │
└─────────────┘       └──────┬──────┘
                              │
                              │ virtio
                              ▼
                      ┌─────────────┐
                      │  OpenWRT    │
                      │   Router    │
                      └─────────────┘
```

### NIC Passthrough

For dedicated hardware:

```nix
custom.vm.quickemu = {
  # ... other options ...
  
  # Disable bridged networking
  network.type = "nat";
  
  # Passthrough NIC
  pciDevice = "0000:03:00.0";
};
```

### VLAN Setup

```bash
# Create VLAN 10 (guest)
uci set network.@switch_vlan[0]=switch_vlan
uci set network.@switch_vlan[0].device='switch0'
uci set network.@switch_vlan[0].vlan='10'
uci set network.@switch_vlan[0].ports='0t 2 3 4'

# Guest network
uci set network.guest=interface
uci set network.guest.device='eth0.10'
uci set network.guest.proto='static'
uci set network.guest.ipaddr='192.168.10.1'
uci set network.guest.netmask='255.255.255.0'

uci commit
```

## Management

### Starting/Stopping

```bash
# Start VM
systemctl start openwrt-router

# Stop VM
systemctl stop openwrt-router

# Enable on boot
systemctl enable openwrt-router
```

### Viewing Logs

```bash
# VM logs
journalctl -u openwrt-router -f

# OpenWRT serial console
# Use dsp-console or:
screen -r openwrt
```

### Backup Configuration

```bash
# From host, copy config
scp root@192.168.1.1:/etc/config/network ~/openwrt-backup/network
scp root@192.168.1.1:/etc/config/firewall ~/openwrt-backup/firewall
```

## Troubleshooting

### VM Won't Start

```bash
# Check logs
journalctl -u openwrt-router -f

# Common issues:
# - Bridge not configured
# - Disk image not found
# - Not enough RAM
```

### No Network

```bash
# Check bridge on host
ip link show br0
ip addr show br0

# Check VM network
ssh root@192.168.1.1 "ip addr"
ssh root@192.168.1.1 "ip route"
```

### Performance Issues

```bash
# Increase RAM if needed
custom.vm.quickemu.memory = 1024;

# Use host CPU for better performance
custom.vm.quickemu.cpuHost = true;
```

## Specification

### Resources

| Resource | Value |
|----------|-------|
| vCPU | 1 |
| RAM | 512MB |
| Storage | 512MB |
| Network | virtio (bridged) or PCI passthrough |

### Supported Features

- [x] NAT routing
- [x] Firewall (iptables/nftables)
- [x] DHCP server
- [x] DNS forwarding
- [x] WiFi (with packages)
- [x] VPN (WireGuard, OpenVPN)
- [x] VLANs
- [x] QoS/SQM
- [x] Ad blocking (with packages)
- [x] Captive portal (with packages)

## See Also

- [VM Manager Overview](../README.md)
- [OpenWRT Documentation](https://openwrt.org/docs/start)
- [OpenWRT Forum](https://forum.openwrt.org/)

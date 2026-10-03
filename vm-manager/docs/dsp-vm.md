# ArchibaldOS DSP VM: the NetJack2 DSP host

Real-time audio processing coprocessor with ultra-low latency.

## Overview

The DSP VM boots an in-tree NixOS guest (`modules/dsp-guest.nix`,
still called "ArchibaldOS" for its hostname/persona), isolated from the
host system. It is a NetJack2 DSP host: its JACK runs jack2's `netmanager`
and the DeMoD engine, and this host (PipeWire) and ArchibaldOS companions
(jack2's `netadapter`, over WireGuard) join it as followers, so their audio
runs through the engine and back. It sits on a routed tap (`10.78.0.2`).

The guest kernel is `linuxPackages_xanmod_latest`, **not** PREEMPT_RT and
**not** CachyOS RT — both were removed from nixpkgs ("removed due to lack
of maintenance"), so the guest module uses XanMod's RT patch set instead.
Any older material that says "RT kernel" or "CachyOS RT" means this now.

### Performance Targets

| Metric | Target | Config |
|--------|--------|--------|
| Round-trip latency | <2ms | **not yet measured** on the XanMod guest — the old CachyOS-RT figures do not carry over, and none has replaced them; see `docs/architecture.md` §10 and `modules/dsp-guest.nix` |
| Sample rate | 96kHz | 96kHz |
| Bit depth | 24-bit | 24-bit |
| Buffer size | 32 samples | 32 (`archibaldOS.netjack.bufferSize`) |
| CPU cores | 1-2 | 0-1 (isolated) |
| Memory | 2-4GB | 2GB (`memoryMB`, `configuration.nix`) |

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

Built directly from this repo's top-level flake — no cloning, no
conversion step. `modules/ArchibaldOS/` is a separate, unrelated
desktop/ISO sub-flake; it is not the DSP guest.

```bash
nix build .#dsp-vm-qcow
```

This produces a `qcow-efi` image (a real ESP for the OVMF firmware the
host runner supplies — a raw/BIOS image here reproduces the exact
failure this guest used to have: OVMF finds no EFI entry and falls
through to an endless PXE netboot loop). On `nixosConfigurations.nixos`
the derivation is already wired into `custom.vm.dsp.archibaldOS.diskImage`
(see `flake.nix`), so there is nothing to copy to `~/vms/`.

### Step 2: Configure the Host

On `.#nixos` the VM is already configured (`configuration.nix`, and the
image wiring in `flake.nix`); turning it on is one line in your local
overrides, because starting it hands the passed-through USB controller to
the guest:

```nix
custom.vm.dsp.enable = true;
```

Elsewhere:

```nix
imports = [ vm-manager.nixosModules.dsp-vm ];

custom.vm.dsp = {
  enable = true;
  isolatedCores = [ 0 1 ];
  memoryMB = 2048;
  hugepages = 1024;
  archibaldOS.diskImage = /path/to/image;   # Oligarchy: built for you
  archibaldOS.netjack = {
    enable = true;
    port = 19000;        # the guest's NetJack2 manager
    bufferSize = 32;     # the guest's JACK period
    sampleRate = 96000;  # the guest's JACK rate
    channels = 2;        # this host <-> the guest
  };
};
```

### Step 3: Rebuild

```bash
sudo nixos-rebuild switch --flake .#nixos-asher   # or .#nixos --impure
```

## What runs where

| | host | guest (`10.78.0.2`) |
|---|---|---|
| network | tap `dsp0` (`10.78.0.1/24`), `networking.interfaces` | static, matched by MAC; the host is the gateway |
| JACK | the user's PipeWire | `dsp-jackd`: the passed-through interface if there is one, else the dummy driver |
| NetJack2 | `dsp-netjack` (user unit): PipeWire's netjack2 driver, a follower | `jack-netmanager` on UDP 19000 |
| engine | | `demod-orchestrator` + `demod-rt` (DeMoD), every follower's 1-2 in, its output back to all of them (`jack-router`) |
| control | `dsp-ctl --transport tcp --host 10.78.0.2` | `dsp-control-bridge`, TCP 7777, admits `10.78.0.1` only |
| remote UI | | `demod-remote-bridge`, DCF on UDP 47000 (a companion kiosk: `remote:10.78.0.2`) |
| ssh | `ssh root@10.78.0.2` (your `custom.user.sshAuthorizedKeys`) | admits `10.78.0.1` only |

The guest image is built from the host's `custom.vm.dsp` values
(`flake.nix`, `mkDspImage`), so addresses, port, rate, period and keys
cannot disagree between the two.

## Companions

With `custom.companions.enable`, the hub's tunnel is in
`network.routed.forwardFrom`: a companion reaches the guest through this
host with UDP and ICMP only (NetJack2, DCF, path-MTU messages), and nothing
else through this host. Forwarding is enabled for the tap and the tunnel
alone (`net.ipv4.conf.<if>.forwarding`), never globally, and an nft table
of its own (`dsp-vm-route.service`, loaded before `network-pre.target`; the
VM requires it) drops everything else to or from either. On the companion:

```nix
# hosts/installed/local.nix (ArchibaldOS)
{ archibald.companion.dsp = { host = "10.78.0.2"; netjack = true; }; }
```

## Usage

```bash
dsp-arm on                         # the VM, then this host's NetJack2 link
systemctl --user start dsp-netjack # the link alone
dsp-status                         # VM, isolation, hugepages, NetJack2
dsp-console                        # the guest's serial console
oligarchy-dsp status               # the control-center view
```

This host then has `dsp-vm.sink` (into the engine) and `dsp-vm.source` (out
of it) in PipeWire. `terminus-dsp-connect start` routes TERMINUS through
them.

## Gates

- `nix build .#dsp-netjack-tests` runs the guest's units, a companion's
  netadapter and this host's `dsp-netjack` in the build sandbox: a tone
  makes the box -> engine -> box and PipeWire app -> engine -> app trips,
  and neither happens before the guest's router exists.
- `nix build .#dsp-route-contract` evaluates `.#nixos` with the VM and the
  companions hub on, and the guest built from it: tap, forwarding scope,
  the forward table (`nft -c`; parse only, with the evaluation reported
  SKIP, where the sandbox refuses a private network namespace, as on
  GitHub's runners), the guest's units and addresses.

## Troubleshooting

```bash
journalctl -u archibaldos-dsp -f          # the VM
journalctl --user -u dsp-netjack -f       # this host's NetJack2 follower
ssh root@10.78.0.2 journalctl -u dsp-jackd -u jack-netmanager -u demod-orchestrator
```

- **`dsp-vm.sink` never appears:** the guest's manager is not answering.
  `ping 10.78.0.2`; on the guest, `systemctl status jack-netmanager`. The
  first line of `dsp-jackd`'s journal says which driver JACK took.
- **IOMMU / VFIO:** AMD-Vi on in firmware; `lspci -nnk` should show the
  controllers on `vfio-pci` while the VM runs.

## Not measured

- `[UNTESTED]` The guest booting under KVM with this configuration: the
  image builds through a KVM job, and nothing here ran one.
- `[UNTESTED]` NetJack2 over the real tap and over WireGuard (MTU 1420 on
  the tunnel; NetJack2 defaults to 1500-byte packets), and its latency.
- `[UNTESTED]` WirePlumber configuring the netjack2 nodes' ports on a real
  desktop; the gate does that step with `pw-cli`.
- The latency figures in `docs/architecture.md` §10 predate the XanMod
  guest and this network; none has been re-measured.

## See Also

- [VM Manager Overview](../README.md)
- `modules/dsp-guest.nix`, `vm-manager/modules/dsp-vm.nix`
- ArchibaldOS `docs/form-factors.md` (the companion side)

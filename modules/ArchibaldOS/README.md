# ArchibaldOS Community Edition (v.1.2-Omega-Alpha-Chad-Syndrome-Maestro)

Old codebase is in a zip file in the release section. I updated the repo to be easier to maintain and learn.

Real-time workstation for audio production and robotics + HydraMesh P2P networking.

What sets it apart? **Bit-for-bit reproducibility** across deployments, ensuring that your setup on a studio workstation matches exactly on a drone brain or secure edge router—eliminating the *"it works on my machine"* syndrome that plagues traditional OSes. Trust us, once you experience deployment consistency at this level, you'll wonder how you ever managed without it.

ArchibaldOS forms the foundational operating system layer for the **DeMoD platform**, a cohesive ecosystem for real-time digital signal processing (DSP) and demodulation. As detailed in the open-source guide at [https://github.com/ALH477/DeMoDulation](https://github.com/ALH477/DeMoDulation)—a public blueprint released by DeMoD LLC on **November 20, 2025**—ArchibaldOS powers **DIY DSP devices** built from e-waste, Framework 13 mainboards, or Raspberry Pi 5. This integration enables **sub-0.8ms round-trip latency at 24-bit/192kHz**, transforming low-cost hardware into professional-grade audio and **software-defined radio (SDR)** rigs. The DeMoDulation repository provides Nix flake profiles that explicitly support ArchibaldOS as a **native or virtualized build option**, ensuring seamless scalability from embedded prototypes to production deployments.

## Who Is ArchibaldOS For?

ArchibaldOS is a **specialized, expert-oriented operating system** designed for users who need **deterministic performance, reproducibility, and deep system control**. It is not intended to be a general-purpose or beginner-friendly Linux distribution.

### **This is for you if you are:**

#### **Professional Audio Engineers & DSP Developers**

* Working with **real-time audio**, live performance rigs, or studio setups
* Comfortable tuning **buffer sizes, IRQ priorities, and CPU governors**
* Requiring **sub-5ms round-trip latency** with measurable, reproducible results
* Building **DSP chains, neural amp models, or SDR-based audio systems**

#### 🤖 **Robotics & Autonomous Systems Engineers**

* Developing with **ROS 2, PX4, LIDAR, and real-time sensor fusion**
* Targeting **ARM SBCs** (Raspberry Pi, Orange Pi, RK3588, etc.)
* Needing **deterministic scheduling** for control loops and autonomy stacks
* Integrating **RF/SDR, audio, and robotics** into a unified real-time system

#### **AI & Systems Engineers (On-Prem / Edge)**

* Running **local LLMs and agentic workflows** without cloud dependency
* Managing **GPU acceleration, memory constraints, and inference pipelines**
* Integrating **voice, audio, and real-time I/O** with AI agents
* Valuing **reproducible, declarative infrastructure** over convenience

#### **Advanced Linux / NixOS Users**

* Already familiar with **NixOS or declarative system management**
* Comfortable editing `flake.nix` and rebuilding systems
* Wanting **bit-for-bit reproducibility** across machines and deployments
* Building custom systems rather than installing off-the-shelf distros

#### **Embedded, Edge, and Defense-Oriented Developers**

* Building **secure, minimal, ITAR/EAR-safe** systems
* Deploying on **e-waste, SBCs, or custom hardware**
* Needing **auditable configurations and deterministic behavior**
* Prioritizing **reliability over UX polish**

---

### **This is probably *not* for you if you are:**

* New to Linux or uncomfortable using the terminal
* Looking for a plug-and-play audio workstation
* Expecting GUI tools for all configuration tasks
* Unwilling to read documentation or debug low-level issues
* Seeking a “daily driver” desktop OS with minimal maintenance
* Unfamiliar with concepts like **xruns, PREEMPT_RT, or JACK/PipeWire tuning**

---

### **Design Philosophy**

ArchibaldOS follows a **“minimal oligarchy” philosophy**:

> Only components that directly contribute to performance, determinism, or reproducibility are included.

Convenience, abstraction, and mass-market usability are **intentionally deprioritized** in favor of:

* Measurable real-time performance
* Declarative, auditable configuration
* Cross-architecture reproducibility
* System-level transparency

If you want an OS that **gets out of your way** and lets you build **serious real-time systems**, ArchibaldOS is for you.

---


**Flake URI:** `github:ALH477/ArchibaldOS`

## License

BSD-3-Clause. See [LICENSE](LICENSE).

## Quick Start

```bash
# Build Audio Workstation ISO (CachyOS RT BORE)
nix build github:ALH477/ArchibaldOS#iso

# Build Robotics Workstation ISO (CachyOS RT BORE)
nix build github:ALH477/ArchibaldOS#robotics-iso

# Build HydraMesh Networking ISO
nix build github:ALH477/ArchibaldOS#hydramesh-iso

# Fallback: musnix PREEMPT_RT kernel variants
nix build github:ALH477/ArchibaldOS#iso-musnix
nix build github:ALH477/ArchibaldOS#robotics-iso-musnix
```

## Kernel Options

| Kernel | Scheduler | Use Case |
|--------|-----------|----------|
| **CachyOS RT** (default) | BORE | Best latency + responsiveness |
| **musnix PREEMPT_RT** (fallback) | CFS | Mainline RT, max compatibility |

Both kernels use the same RT parameters:
- `threadirqs` - Threaded IRQ handlers
- `isolcpus=1-3` - Isolated CPU cores
- `nohz_full=1-3` - Full tickless
- `intel_idle.max_cstate=1` - Disable deep C-states

## Profiles

| Profile | ISO | Description |
|---------|-----|-------------|
| **Audio** | `iso` | RT audio production with DAWs, synths, DSP tools |
| **Robotics** | `robotics-iso` | RT control systems, simulation, hardware I/O |
| **HydraMesh** | `hydramesh-iso` | Headless P2P networking node |

## Audio Profile

- **Kernel**: CachyOS RT with BORE scheduler
- **Latency**: 32 samples @ 96kHz (~0.33ms)
- **DAWs**: Ardour, Audacity, Zrythm, Reaper
- **Synths**: Surge, Helm, Carla
- **DSP**: Csound, Faust, SuperCollider, Pure Data
- **Desktop**: Plasma 6 with Wayland

## Robotics Profile

Same RT kernel optimized for control systems:

- **Simulation**: Gazebo, Blender
- **CAD/EDA**: FreeCAD, OpenSCAD, KiCad
- **Development**: CMake, GCC, Clang, Python, VS Code
- **Hardware**: Arduino IDE, serial tools, CAN bus
- **Vision**: OpenCV
- **Control**: Octave, NumPy, SciPy, control library

### Hardware Support

Preconfigured udev rules for:
- Arduino (all variants)
- FTDI USB-serial
- STM32 (DFU mode)
- Teensy
- Generic USB serial

## HydraMesh P2P

Sub-10ms latency networking:

```nix
services.hydramesh = {
  enable = true;
  mode = "p2p";
  peers = [ "192.168.1.100:7777" ];
};
```

## Community vs Pro

| Feature | Community | Pro |
|---------|-----------|-----|
| CachyOS RT BORE kernel | ✅ | ✅ |
| musnix PREEMPT_RT fallback | ✅ | ✅ |
| Audio Profile | ✅ | ✅ |
| Robotics Profile | ✅ | ✅ |
| HydraMesh P2P | ✅ | ✅ |
| x86_64 Desktop ISOs | ✅ | ✅ |
| **ARM Support** | ❌ | ✅ Orange Pi 5, RPi |
| **Thunderbolt/USB4** | ❌ | ✅ 40Gbps |
| **Auto-updates** | ❌ | ✅ With rollback |
| **AppArmor + audit** | ❌ | ✅ |
| **DSP Coprocessor** | ❌ | ✅ |
| **Enterprise configs** | ❌ | ✅ |

Pro: https://github.com/ALH477/archibaldos-pro

## Development

```bash
# Audio dev shell
nix develop github:ALH477/ArchibaldOS

# Robotics dev shell
nix develop github:ALH477/ArchibaldOS#robotics
```

## Credits

- [CachyOS](https://cachyos.org) - BORE scheduler and optimized kernels
- [musnix](https://github.com/musnix/musnix) - Real-time audio NixOS module
- [chaotic-nyx](https://github.com/chaotic-cx/nyx) - CachyOS packages for NixOS
- [NixOS](https://nixos.org) - The reproducible Linux distribution

---

Copyright (c) 2025 DeMoD LLC. All rights reserved.

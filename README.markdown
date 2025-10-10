# Oligarchy NixOS

Oligarchy NixOS is a custom NixOS distribution optimized for the Framework Laptop 16 (AMD Ryzen 7040 series), designed for developers, creators, gamers, and Framework enthusiasts. Inspired by Omarchy’s seamless installation, it provides a lightweight Hyprland desktop, a guided TUI installer, and extensive customization options. The system supports Flatpak and Snap packages, a robust gaming suite, and hardware-specific optimizations, ensuring performance, low power consumption, and flexibility on Framework 16 and other hardware.

![Oligarchy](https://repository-images.githubusercontent.com/1072001868/8b510033-8549-4c89-995d-d40f79680900)

## Why Oligarchy NixOS is Optimized and Supreme

- **Low Idle Power Consumption**: Tailored for the Framework Laptop 16 with power-efficient settings:
  - **Power Profiles Daemon**: Dynamically adjusts CPU performance to minimize idle power usage (`power-profiles-daemon` enables balanced/low-power modes).
  - **AMDGPU Configuration**: Fine-tuned kernel parameters (`amdgpu.abmlevel=0`, `amdgpu.sg_display=0`, `amdgpu.exp_hw_support=1`) optimize GPU power draw, reducing idle consumption to as low as 5-7W on Framework 16.
  - **Fan Control**: `fw-fanctrl` ensures efficient cooling, reducing fan activity during low loads, further lowering power usage.
  - **Lid Switch Handling**: Configurable lid close behavior (`lid.sh`, `toggle_clamshell.sh`) disables the display to save power in clamshell mode.
- **Framework 16 Compatibility**: Leverages `nixos-hardware` and `fw-fanctrl` for AMD Ryzen 7040 support, including GPU drivers (`amdgpu`), firmware updates (`fwupd`), and fingerprint authentication (`fprintd`). Optional toggle ensures compatibility with other hardware.
- **Modular Package Management**: Nix’s declarative configuration allows precise control. Gaming (`steam`, `dhewm3`, `r2modman`, `darkradiant`) and Snap support are optional, keeping the system lean.
- **Lightweight Desktop**: Hyprland with Waybar and Wofi provides a fast, Wayland-based environment, minimizing resource usage while supporting multi-monitor and clamshell setups.
- **Streamlined Installation**: TUI installer simplifies disk setup (LUKS-encrypted ext4), user configuration, and hardware options, ensuring quick deployment.
- **Customization Scripts**: Tools for resolution cycling, Hyprland configuration, theme switching, and web app integration enhance user control, accessible via Wofi or keybindings.
- **Flatpak and Snap Support**: Flatpak is enabled by default for broad application access. Snap is optional, expanding software availability without compromising Nix’s reproducibility.

## Who and What It’s Good For.

Oligarchy NixOS is ideal for:
- **Developers**: Offers a robust toolset for programming (gcc, rustc, Python, Go, SBCL with Lisp packages, Docker) and networking (Wireshark, nmap, Mininet). The lightweight Hyprland desktop and VS Code server (`openvscode-server`) ensure efficient workflows.
- **Creators**: Includes a comprehensive multimedia suite (Blender, Kdenlive, GIMP, Inkscape, Audacity, Ardour) for video editing, 3D modeling, and audio production, with hardware-accelerated graphics via Mesa and AMD Vulkan.
- **Gamers**: Optional gaming toggle provides Steam, Lutris, Wine, dhewm3 (Doom 3 port), r2modman (mod manager), and DarkRadiant (level editor), optimized for Framework 16’s GPU performance.
- **Framework Enthusiasts**: Tailored for Framework Laptop 16 with power-efficient settings, fan control, and hardware support, while remaining compatible with other systems via a flexible installer.
- **General Users**: Flatpak and Snap support allow easy installation of popular apps (e.g., Spotify, Discord), while Wofi and web app integration streamline access to tools and services.

Use cases include software development, content creation, gaming, and running a lightweight, secure Linux system on modern hardware.

## Features for the Masses

- **Guided TUI Installer**: Prompts for keyboard layout, disk (LUKS-encrypted ext4), Framework hardware support, locale, timezone, hostname, user accounts, gaming, and Snap support.
- **Hyprland Desktop**: Fast Wayland compositor with Waybar (system status) and Wofi (application launcher), configured for multi-monitor and clamshell mode.
- **Customization Scripts**:
  - `toggle_resolution`: Cycle monitor resolutions (`SUPER+SHIFT+W` or Wofi).
  - `hyprland_config_modifier`: Edit Hyprland wallpaper/keybindings (`SUPER+SHIFT+P` or Wofi).
  - `theme_changer`: Switch color schemes (green, blue, red, purple, Nord, Dracula, Gruvbox, Solarized, Catppuccin, Tokyo Night, custom) (`SUPER+SHIFT+T` or Wofi).
  - `webapp_to_wofi`: Add web apps to Wofi (`SUPER+SHIFT+A` or Wofi), supporting Firefox, Brave, or default browser.
- **Gaming Support**: Optional toggle for Steam, Lutris, Wine, dhewm3, r2modman, and DarkRadiant.
- **Flatpak and Snap**: Install Flatpaks by default (`flatpak install flathub <app-id>`). Enable Snap during installation for additional package support (`snap install <package>`).
- **Framework 16 Optimization**: Hardware-specific modules for AMD Ryzen 7040, with fallback for other systems.
- **Comprehensive Packages**: Development, multimedia, networking, and utilities (see below).

## Packages from the Elite

### Main Packages
Always installed, covering development, multimedia, networking, utilities, and desktop environment:
- **Development Tools**:
  - `vim`: Text editor
  - `docker`: Containerization
  - `git`, `git-lfs`, `gh`: Version control and GitHub CLI
  - `cmake`, `gcc`, `gnumake`, `ninja`: Build systems
  - `rustc`, `cargo`: Rust development
  - `go`: Go programming
  - `openssl`, `gnutls`, `pkgconf`, `snappy`: Cryptography and build tools
  - `python3Full` with `pip`, `virtualenv`, `cryptography`, `pycryptodome`, `grpcio`, `grpcio-tools`, `protobuf`, `numpy`, `matplotlib`, `python-snappy`
  - `perl` with `JSON`, `GetoptLong`, `CursesUI`, `ModulePluggable`, `Appcpanminus`
  - `sbcl` with `cffi`, `cl-ppcre`, `cl-json`, `cl-csv`, `usocket`, `bordeaux-threads`, `log4cl`, `trivial-backtrace`, `cl-store`, `hunchensocket`, `fiveam`, `cl-dot`, `cserial-port`
  - `libserialport`, `can-utils`, `lksctp-tools`, `cjson`, `ncurses`, `libuuid`: Hardware and networking libraries
  - `kicad`, `graphviz`, `mako`, `openscad`, `freecad`: PCB design and CAD
- **Multimedia**:
  - `ardour`, `audacity`, `ffmpeg-full`, `jack2`, `qjackctl`, `libpulseaudio`, `pkgsi686Linux.libpulseaudio`, `pavucontrol`, `guitarix`: Audio production
  - `vlc`, `obs-studio`: Media playback and streaming
  - `gimp`, `kdePackages.kdenlive`, `inkscape`, `blender`, `libreoffice`, `krita`: Graphics and video editing
- **Networking**:
  - `wireshark`, `tcpdump`, `nmap`, `netcat`, `mininet`: Network analysis and emulation
  - `blueberry`: Bluetooth management
  - `networkmanager`: Network configuration (enabled separately)
- **Utilities**:
  - `htop`, `nvme-cli`, `lm_sensors`, `s-tui`, `stress`, `dmidecode`, `util-linux`, `gparted`, `usbutils`: System monitoring and disk management
  - `zip`, `unzip`, `fastfetch`, `gnugrep`, `systemctl-tui`: File and system utilities
  - `unetbootin`, `popsicle`, `gnome-disk-utility`, `framework-tool`: USB and Framework utilities
- **Desktop Environment**:
  - `kitty`, `wofi`, `waybar`, `hyprpaper`, `brightnessctl`, `wl-clipboard`, `grim`, `slurp`, `v4l-utils`: Hyprland tools
  - `xfce.thunar`, `xfce.thunar-volman`, `gvfs`, `udiskie`, `polkit_gnome`, `font-awesome`: File management and desktop utilities
  - `xorg.xinit`: X server support
- **Virtualization**:
  - `qemu`, `virt-manager`, `docker-compose`, `docker-buildx`: Virtualization and container tools
- **Graphics**:
  - `vulkan-tools`, `vulkan-loader`, `vulkan-validation-layers`, `libva-utils`: Vulkan and VAAPI
  - `mesa`, `amdvlk`, `vaapiVdpau`, `libvdpau-va-gl`, `rocmPackages.clr.icd`: Graphics drivers
- **Browsers/Productivity**:
  - `brave`, `firefox`, `thunderbird`, `pandoc`, `kdePackages.okular`, `vesktop`: Web, email, and documents
- **Development Servers**:
  - `unstable.openvscode-server`: VS Code server (from nixpkgs-unstable)

### Optional Gaming Packages for Optimal State Sanctioned Entertainment 
Enabled with `custom.steam.enable` (prompted during install):
- `steam`, `steam-run`, `linuxConsoleTools`, `lutris`, `wineWowPackages.stable`, `dhewm3`, `r2modman`, `darkradiant`, `proton-ge-bin` (via `programs.steam.extraCompatPackages`)

### Installer Dependencies
Included in the live ISO for installation:
- `disko`: Disk partitioning
- `dialog`: TUI framework
- `python3`: Script runtime

### Flatpak and Snap Apologists
- **Flatpak**: Enabled by default (`services.flatpak.enable`). Install with:
  ```bash
  flatpak install flathub <app-id>
  ```
  Example: `flatpak install flathub com.spotify.Client`
- **Snap**: Optional (`custom.snap.enable`). Install with:
  ```bash
  snap install <package>
  ```
  Example: `snap install core; snap install hello-world`

## Prerequisites for Worthiness

- A system with Nix installed (or a NixOS environment).
- Framework Laptop 16 (AMD Ryzen 7040 series) for optimal hardware support, though compatible with other hardware.
- USB drive for flashing the ISO.
- `wallpaper.jpg` in the repository root for the default Hyprland wallpaper.
- Internet access for fetching dependencies (optional for offline installs).

## Installation

1. **Clone the Repository**:
   ```bash
   git clone https://github.com/ALH477/DeMoD-Framework16-NIXOS
   cd DeMoD-Framework16-NIXOS
   ```

2. **Ensure Wallpaper**:
   Place `wallpaper.jpg` in the repository root.

3. **Build the ISO**:
   ```bash
   nix build .#nixosConfigurations.iso.config.system.build.isoImage
   ```

4. **Flash to USB**:
   Identify your USB device (`/dev/sdX`) with `lsblk`, then:
   ```bash
   sudo dd if=result/iso/nixos-*.iso of=/dev/sdX bs=4M status=progress
   sync
   ```

5. **Boot and Install**:
   - Boot from the USB drive (login: `nixos`, password: `nixos`).
   - The installer starts in a Kitty terminal, displaying the Oligarchy ASCII logo.
   - Follow the TUI prompts:
     - **Keyboard Layout**: Select from a menu (e.g., `us`, `gb`).
     - **Disk**: Choose a disk to wipe and install (LUKS-encrypted ext4).
     - **Framework Hardware**: Enable/disable Framework 16 optimizations.
     - **Locale/Timezone**: Set language and region (e.g., `en_US.UTF-8`, `America/Los_Angeles`).
     - **Hostname/Username**: Configure system and user identity.
     - **Passwords**: Set user and optional root passwords.
     - **Gaming**: Enable Steam, dhewm3, r2modman, DarkRadiant, and related packages.
     - **Snap**: Enable Snap package support.
   - Reboot into the new system (enter LUKS password at boot).

6. **Test in QEMU** (optional):
   ```bash
   qemu-system-x86_64 -cdrom result/iso/nixos-*.iso -m 4G -enable-kvm -cpu host
   ```

## State Sanctioned Usage

- **Desktop**: Hyprland with Waybar (CPU, memory, battery, network status) and Wofi (launch apps with `SUPER+D`).
- **Customization**:
  - **Resolution**: Cycle with `SUPER+SHIFT+W` or `SUPER+SHIFT+F1-F5`, or run `toggle_resolution` via Wofi/terminal.
  - **Config**: Modify Hyprland settings with `SUPER+SHIFT+P` or `hyprland_config_modifier`.
  - **Themes**: Switch color schemes with `SUPER+SHIFT+T` or `theme_changer`.
  - **Web Apps**: Add web apps to Wofi with `SUPER+SHIFT+A` or `webapp_to_wofi` (choose Firefox, Brave, or default browser).
- **Gaming**:
  - If enabled, run `steam`, `dhewm3` (requires Doom 3 data files), `r2modman` for modded games, or `darkradiant` for level editing.
- **Flatpak**:
  - Install: `flatpak install flathub <app-id>` (e.g., `flatpak install flathub com.spotify.Client`).
  - Run: `flatpak run com.spotify.Client`.
- **Snap**:
  - If enabled, install: `snap install <package>` (e.g., `snap install core; snap install hello-world`).
  - Run: `snap run hello-world`.
- **Wallpaper**: Place your wallpaper at `~/Pictures/wall.jpg` or use the default (`/etc/nixos/hypr/wallpaper.jpg`).

## Contributing

Contributions are nascent. Fork. Submit pull requests or issues to the [GitHub repository](https://github.com/ALH477/Oligarchy). Ensure changes maintain compatibility with NixOS and Framework 16. 

## License

This project is licensed under the BSD 3-Clause License, be thankful:

```
Copyright (c) 2025, DeMoD LLC

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its
   contributors may be used to endorse or promote products derived from
   this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
```

## Notes
- **Doom 3**: `dhewm3` requires separately owned Doom 3 data files (e.g., from Steam).
- **Wallpaper**: Ensure `wallpaper.jpg` is in the repository root before building the ISO.
- **Validation**: Locale/timezone inputs are not validated; use standard formats (e.g., `en_US.UTF-8`, `America/Los_Angeles`).
- **Flatpak/Snap**: Flatpak is enabled by default; Snap requires enabling during installation. Use `flatpak` or `snap` commands post-install.
- **Support**: For issues, check the [NixOS Wiki](https://nixos.wiki) or open a GitHub issue.

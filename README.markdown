# Oligarchy NixOS

![Oligarchy](ascii-art-text.jpg)

Oligarchy NixOS is a custom NixOS distribution optimized for the Framework Laptop 16 (AMD Ryzen 7040 series), designed for developers, creators, and gamers. Inspired by Omarchy’s seamless installation, it provides a lightweight Hyprland desktop, a guided TUI installer, and extensive customization options. The system supports Flatpak and Snap packages, a robust gaming suite, and hardware-specific optimizations, ensuring performance and flexibility on Framework 16 and other hardware.

## Why Oligarchy NixOS is Optimized

- **Framework 16 Compatibility**: Leverages `nixos-hardware` and `fw-fanctrl` for tailored AMD Ryzen 7040 support, including GPU drivers (`amdgpu`), power management, and firmware updates (`fwupd`). Optional toggle ensures compatibility with other hardware.
- **Modular Package Management**: Nix’s declarative configuration allows precise control over packages. The gaming toggle (`steam`, `dhewm3`, `r2modman`, `darkradiant`, etc.) and Snap support are optional, keeping the system lean for non-gamers or Snap-free setups.
- **Lightweight Desktop**: Hyprland with Waybar and Wofi provides a fast, modern Wayland experience, minimizing resource usage while supporting advanced features like XWayland and multi-monitor setups.
- **Streamlined Installation**: The TUI installer simplifies disk setup (LUKS-encrypted ext4), user configuration, and hardware options, making deployment quick and reliable.
- **Customization Scripts**: Tools for resolution cycling, Hyprland configuration, theme switching, and web app integration enhance user control, accessible via Wofi or keybindings.
- **Flatpak and Snap Support**: Flatpak is enabled by default for easy access to a wide range of applications. Snap is optional, broadening software availability without compromising Nix’s reproducibility.

## Features

- **Guided TUI Installer**: Prompts for keyboard layout, disk (LUKS-encrypted ext4), Framework hardware support, locale, timezone, hostname, user accounts, gaming, and Snap support.
- **Hyprland Desktop**: Fast Wayland compositor with Waybar (system status) and Wofi (application launcher), configured for multi-monitor and clamshell mode.
- **Customization Scripts**:
  - `toggle_resolution`: Cycle monitor resolutions (`SUPER+SHIFT+W` or Wofi).
  - `hyprland_config_modifier`: Edit Hyprland wallpaper/keybindings (`SUPER+SHIFT+P` or Wofi).
  - `theme_changer`: Switch color schemes (green, blue, red, purple, Nord, Dracula, Gruvbox, Solarized, Catppuccin, Tokyo Night, custom) (`SUPER+SHIFT+T` or Wofi).
  - `webapp_to_wofi`: Add web apps to Wofi (`SUPER+SHIFT+A` or Wofi), supporting Firefox, Brave, or default browser.
- **Gaming Support**: Optional toggle for Steam, Lutris, Wine, dhewm3 (Doom 3 port), r2modman (Thunderstore mod manager), and DarkRadiant (level editor).
- **Flatpak and Snap**: Install Flatpaks by default (`flatpak install flathub <app-id>`). Enable Snap during installation for additional package support (`snap install <package>`).
- **Comprehensive Packages**: Includes development tools (gcc, rustc, Python), multimedia (Blender, FFmpeg), networking (Wireshark, nmap), and utilities (gparted, firefox).

## Prerequisites

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

## Usage

- **Desktop**: Hyprland with Waybar (system status: CPU, memory, battery, network) and Wofi (launch apps with `SUPER+D`).
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

Contributions are welcome! Submit pull requests or issues to the [GitHub repository](https://github.com/ALH477/DeMoD-Framework16-NIXOS). Ensure changes maintain compatibility with NixOS and Framework 16.

## License

This project is licensed under the BSD 3-Clause License:

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

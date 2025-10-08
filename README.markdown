# Oligarchy NixOS

Oligarchy NixOS is a custom NixOS distribution optimized for the Framework Laptop 16 (AMD Ryzen 7040 series), inspired by the seamless installation experience of Omarchy. It provides a polished Hyprland desktop with VIM-green aesthetics, Sierpinski fractal-inspired animations, and DeMoD LLC branding. The installer offers a guided TUI for configuring locale, timezone, hostname, user accounts, disk encryption, and optional gaming support, delivering a modern, customizable Linux environment for developers, creators, and gamers.

## Features

- **Streamlined Installation**: Omarchy-like TUI with foolproof prompts for keyboard, disk (LUKS-encrypted ext4), Framework hardware support, locale, timezone, hostname, user accounts, and gaming.
- **Hyprland Desktop**: VIM-green themed Wayland compositor with Sierpinski-inspired animations, Waybar, and Wofi for a cohesive, modern look.
- **Customization Scripts**:
  - `toggle_resolution`: Cycle monitor resolutions (`SUPER+SHIFT+W`).
  - `hyprland_config_modifier`: Modify Hyprland wallpaper/keybindings (`SUPER+SHIFT+P`).
  - `theme_changer`: Switch color schemes (green, blue, red, purple, Nord, Dracula, Gruvbox, Solarized, Catppuccin, Tokyo Night, custom) (`SUPER+SHIFT+T`).
  - `webapp_to_wofi`: Add web apps to Wofi launcher (`SUPER+SHIFT+A`).
- **Wofi Integration**: All scripts accessible via Wofi (`SUPER+D`) or terminal.
- **Gaming Support**: Optional toggle for Steam, Lutris, Wine, dhewm3 (Doom 3 port), and r2modman (Thunderstore mod manager).
- **Framework 16 Optimization**: Hardware-specific modules for AMD Ryzen 7040, with fallback for other systems.
- **Comprehensive Packages**: Development tools (gcc, rustc, Python), multimedia (Blender, FFmpeg), networking (Wireshark, nmap), and more.

## Prerequisites

- A system with Nix installed (or a NixOS environment).
- Framework Laptop 16 (AMD Ryzen 7040 series) for optimal hardware support, though compatible with other hardware.
- USB drive for flashing the ISO.
- Internet access for fetching dependencies (optional for offline installs).

## Installation

1. **Clone the Repository**:
   ```bash
   git clone https://github.com/ALH477/DeMoD-Framework16-NIXOS
   cd DeMoD-Framework16-NIXOS
   ```

2. **Build the ISO**:
   ```bash
   nix build .#nixosConfigurations.iso.config.system.build.isoImage
   ```

3. **Flash to USB**:
   Identify your USB device (`/dev/sdX`) with `lsblk`, then:
   ```bash
   sudo dd if=result/iso/nixos-*.iso of=/dev/sdX bs=4M status=progress
   sync
   ```

4. **Boot and Install**:
   - Boot from the USB drive (login: `nixos`, password: `nixos`).
   - The installer starts automatically in a Kitty terminal, displaying the Oligarchy ASCII logo.
   - Follow the TUI prompts:
     - **Keyboard Layout**: Select from a menu (e.g., `us`, `gb`).
     - **Disk**: Choose a disk to wipe and install (LUKS-encrypted ext4).
     - **Framework Hardware**: Enable/disable Framework 16 optimizations.
     - **Locale/Timezone**: Set language and region (e.g., `en_US.UTF-8`, `America/Los_Angeles`).
     - **Hostname/Username**: Configure system and user identity.
     - **Passwords**: Set user and optional root passwords.
     - **Gaming**: Enable Steam, dhewm3, r2modman, and related packages.
   - After installation, reboot into the new system (enter LUKS password at boot).

5. **Test in QEMU** (optional):
   ```bash
   qemu-system-x86_64 -cdrom result/iso/nixos-*.iso -m 4G -enable-kvm -cpu host
   ```

## Usage

- **Desktop**: Hyprland with VIM-green borders, Sierpinski animations, and Waybar/Wofi (launch apps with `SUPER+D`).
- **Customization**:
  - **Resolution**: Cycle with `SUPER+SHIFT+W` or `SUPER+SHIFT+F1-F5`, or run `toggle_resolution` via Wofi/terminal.
  - **Config**: Modify Hyprland settings with `SUPER+SHIFT+P` or `hyprland_config_modifier`.
  - **Themes**: Switch color schemes with `SUPER+SHIFT+T` or `theme_changer` (supports green, blue, red, purple, Nord, Dracula, Gruvbox, Solarized, Catppuccin, Tokyo Night, custom).
  - **Web Apps**: Add web apps to Wofi with `SUPER+SHIFT+A` or `webapp_to_wofi` (supports Firefox, Brave, default browser).
- **Gaming**:
  - If enabled, run `steam`, `dhewm3` (requires Doom 3 data files), or `r2modman` for modded games.
- **Wallpaper**: Place your wallpaper at `~/Pictures/wall.jpg` or use the default Sierpinski fractal (`/etc/nixos/hypr/sierpinski.jpg`).

## Contributing

Contributions are welcome! Please submit pull requests or issues to the [GitHub repository](https://github.com/ALH477/DeMoD-Framework16-NIXOS). Ensure changes align with the VIM-green, Sierpinski aesthetic and maintain compatibility with NixOS and Framework 16.

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
- **Wallpaper**: Replace the placeholder Sierpinski URL/SHA256 with a valid image (compute SHA256 with `nix-prefetch-url`).
- **Validation**: Locale/timezone inputs are not validated; use standard formats to avoid errors.
- **Support**: For issues, check the [NixOS Wiki](https://nixos.wiki) or open a GitHub issue.
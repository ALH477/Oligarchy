# DeMoD Workstation Configuration

A comprehensive NixOS home-manager configuration for a production-grade Hyprland desktop environment with KDE Plasma 6 compatibility, gaming support, and a unified theming system.

## Table of Contents

1. [Overview](#overview)
2. [Requirements](#requirements)
3. [Installation](#installation)
4. [Configuration Structure](#configuration-structure)
5. [Theme System](#theme-system)
6. [Feature Flags](#feature-flags)
7. [Keybindings](#keybindings)
8. [Components](#components)
9. [Scripts](#scripts)
10. [Gaming Support](#gaming-support)
11. [XWayland Compatibility](#xwayland-compatibility)
12. [Customization](#customization)
13. [Troubleshooting](#troubleshooting)
14. [License](#license)

---

## Overview

This configuration provides a complete desktop environment built on Hyprland with the following characteristics:

- Unified theming across Hyprland, Waybar, GTK, Qt, and KDE applications
- Eight switchable color palettes with runtime theme switching
- Hardware-accelerated screen recording with GPU Screen Recorder
- Gaming optimizations with gamemode integration
- Full XWayland support for legacy X11 applications
- Comprehensive keybinding system with popup cheat sheet
- Power management with lid switch handling
- Professional notification system with Mako

---

## Requirements

### System Requirements

- NixOS 25.11 or later
- Home Manager
- Hyprland-compatible GPU (AMD, Intel, or NVIDIA)
- Wayland-capable display server

### Hardware Features

The configuration automatically adapts based on hardware capabilities defined in the feature flags section.

---

## Installation

1. Place the configuration file in your NixOS configuration directory:

```bash
cp asher.nix /etc/nixos/home/asher.nix
```

2. Import the home-manager module in your `flake.nix` or `configuration.nix`.

3. Modify the username and home directory variables at the top of the file:

```nix
username = "your-username";
homeDirectory = "/home/${username}";
```

4. Adjust feature flags according to your hardware.

5. Rebuild the system:

```bash
sudo nixos-rebuild switch --flake .
```

---

## Configuration Structure

The configuration is organized into the following major sections:

| Section | Description |
|---------|-------------|
| Theme System | Color palettes and theme switching infrastructure |
| Feature Flags | Hardware and software capability toggles |
| Packages | System and user packages organized by category |
| XDG | Desktop integration and portal configuration |
| KDE Plasma 6 | Complete Plasma theming for Qt applications |
| Hyprland | Window manager configuration and keybindings |
| Waybar | Status bar with custom modules |
| Application Configs | Kitty, Mako, Wofi, wlogout, and others |
| Scripts | Automation scripts for various tasks |
| Shell | Bash configuration with aliases and prompt |

---

## Theme System

### Available Palettes

The configuration includes eight color palettes that can be switched at runtime:

| Palette | Description |
|---------|-------------|
| DeMoD | Retro-tech aesthetic with turquoise and violet accents on deep black |
| Catppuccin | Cozy pastel theme with warm undertones |
| Nord | Frozen and calm arctic color scheme |
| Rose Pine | Elegant and muted with rose accents |
| Dracula | Classic dark theme with purple highlights |
| Gruvbox | Warm and earthy retro palette |
| Tokyo Night | Modern theme with Japanese aesthetics |
| Phosphor | Maximum retro terminal energy with green phosphor glow |

### Theme Switching

- `Super + F8` - Cycle to next theme
- `Super + Shift + F8` - Open theme selection menu

Theme changes are applied in real-time to:

- Hyprland borders and decorations
- Waybar styling
- Terminal colors
- GTK and Qt applications (requires application restart)

### Default Theme

The default palette is set via the `defaultPalette` variable:

```nix
defaultPalette = "demod";
```

---

## Feature Flags

Hardware and software capabilities are controlled through feature flags:

```nix
features = {
  hasBattery = true;      # Laptop with battery
  hasBluetooth = true;    # Bluetooth adapter present
  hasBacklight = true;    # Screen brightness control
  hasTouchpad = true;     # Touchpad present
  enableDCF = true;       # DeMoD Communication Framework
  enableAIStack = true;   # Local AI inference tools
  enableGaming = true;    # Gaming packages and optimizations
  enableDev = true;       # Development tools
};
```

### Flag Effects

| Flag | Enables |
|------|---------|
| hasBattery | Power management, lid switch scripts, battery indicator |
| hasBluetooth | Blueman applet, Bluetooth waybar module |
| hasBacklight | Brightness controls, backlight waybar module |
| hasTouchpad | Gesture configuration, tap-to-click |
| enableDCF | DCF tray application, control keybinds |
| enableAIStack | Local AI tools and inference packages |
| enableGaming | Steam, Lutris, gamemode, MangoHUD, Wine |
| enableDev | VS Code, Obsidian, Git tools, btop |

---

## Keybindings

### Core

| Binding | Action |
|---------|--------|
| Super + / | Keybind help popup |
| Super + F1 | Keybind help popup |
| Super + Space | Application launcher |
| Super + Return | Terminal |
| Super + Shift + Return | Floating terminal |
| Super + B | Browser |
| Super + E | File manager |
| Super + C | VS Code (if enableDev) |
| Super + O | Obsidian (if enableDev) |

### Window Management

| Binding | Action |
|---------|--------|
| Super + Q | Close window |
| Super + Shift + Q | Kill window (click to select) |
| Super + W | Toggle floating |
| Super + F | Fullscreen |
| Super + Shift + F | Fake fullscreen |
| Super + P | Pseudo-tile |
| Super + X | Toggle split direction |
| Super + Shift + C | Center window |
| Super + Shift + P | Pin window |

### Navigation

| Binding | Action |
|---------|--------|
| Super + H/J/K/L | Focus left/down/up/right |
| Super + Arrow keys | Focus direction |
| Super + Shift + H/J/K/L | Move window |
| Super + Ctrl + H/J/K/L | Resize window |
| Super + U | Focus urgent or last |

### Workspaces

| Binding | Action |
|---------|--------|
| Super + 1-0 | Switch to workspace 1-10 |
| Super + Shift + 1-0 | Move window to workspace |
| Super + Grave | Previous workspace |
| Super + [ / ] | Previous/next workspace |
| Super + S | Toggle scratchpad |
| Super + Shift + S | Move to scratchpad |

### Screenshots

| Binding | Action |
|---------|--------|
| Print | Full screen capture |
| Super + Print | Active window capture |
| Shift + Print | Region selection |
| Super + Shift + Print | Region with editor |
| Super + Shift + X | Color picker |

### Screen Recording

| Binding | Action |
|---------|--------|
| Super + R | Toggle recording |
| Super + Alt + R | Record region |
| Super + Ctrl + R | Toggle replay buffer |
| Super + Shift + R | Save replay |

### System

| Binding | Action |
|---------|--------|
| Super + T | Thermal status |
| Super + M | System monitor |
| Super + = | Calculator |
| Super + Escape | Power menu |
| Super + Ctrl + L | Lock screen |
| Super + Shift + Escape | Exit Hyprland |
| Super + F8 | Cycle theme |
| Super + Shift + F8 | Theme menu |
| Super + F9 | Toggle game mode |
| Super + Shift + F9 | MangoHUD overlay |

---

## Components

### Waybar

The status bar includes the following modules:

**Left:**
- DeMoD logo (launcher)
- Workspace indicators
- Submap indicator
- Window title

**Center:**
- Clock with calendar

**Right:**
- Game mode indicator (if enableGaming)
- Recording status
- Media player controls
- Backlight (if hasBacklight)
- Audio controls (volume and microphone)
- Network status
- Bluetooth (if hasBluetooth)
- System stats (CPU, memory, temperature)
- Battery (if hasBattery)
- System tray
- Power button

### Notifications (Mako)

- Position: Top-right
- Maximum visible: 4
- Urgency-based styling and timeouts
- Category grouping for volume and brightness

### Application Launcher (Wofi)

- Centered overlay
- Application icons
- Fuzzy search
- DeMoD-themed styling

### Lock Screen (Hyprlock)

- Screenshot-based blurred background
- Time and date display
- User indicator
- Themed input field

### Idle Management (Hypridle)

| Timeout | Action |
|---------|--------|
| 4 minutes | Dim screen to 10% |
| 5 minutes | Lock session |
| 6 minutes | Turn off display |
| 10 minutes | Suspend system |

---

## Scripts

The configuration includes several automation scripts located in `~/.config/hypr/scripts/`:

| Script | Purpose |
|--------|---------|
| keybind-help.sh | Display keybinding cheat sheet |
| screenshot.sh | Screen capture with multiple modes |
| record.sh | GPU-accelerated screen recording |
| gamemode.sh | Gaming optimization toggle |
| volume.sh | Volume control with notifications |
| brightness.sh | Brightness control with notifications |
| theme-switcher.sh | Runtime theme switching |
| lid.sh | Laptop lid switch handling |
| toggle_clamshell.sh | Clamshell mode toggle |

### Recording Script Features

- Hardware-accelerated encoding via GPU Screen Recorder
- Multiple modes: full screen, region selection, replay buffer
- Waybar integration with status indicator
- Automatic file organization in ~/Videos/Recordings and ~/Videos/Replays

### Gamemode Script Features

When activated, game mode:

- Disables compositor animations
- Disables blur and shadows
- Removes window gaps
- Forces VRR mode
- Integrates with Feral GameMode daemon

---

## Gaming Support

When `enableGaming = true`, the following packages are installed:

| Package | Purpose |
|---------|---------|
| Steam | Game distribution platform |
| Gamescope | Micro-compositor for games |
| MangoHUD | Performance overlay |
| GameMode | CPU/GPU optimization daemon |
| Lutris | Game launcher |
| Wine Staging | Windows compatibility layer |
| Winetricks | Wine configuration helper |
| Protontricks | Proton configuration helper |
| DXVK | DirectX 9/10/11 to Vulkan |
| VKD3D-Proton | DirectX 12 to Vulkan |

### Gaming Environment Variables

The configuration sets optimal environment variables for gaming:

- VRR/FreeSync enabled
- AMD Vulkan optimizations (RADV)
- Wine FSR enabled
- DXVK async compilation
- Steam UI scaling

### Gaming Window Rules

Games receive special window treatment:

- Immediate rendering mode
- Fullscreen behavior
- Idle inhibition
- No blur or shadows

---

## XWayland Compatibility

The configuration includes comprehensive XWayland support:

### Packages

- xrandr, xprop, xdpyinfo, xhost
- xclip, xsel for clipboard

### Hyprland Settings

- Force zero scaling for crisp rendering
- Proper cursor synchronization
- Hardware cursor compatibility mode

### Environment Variables

- Proper cursor theme propagation
- Qt and GTK backend configuration
- Java AWT compatibility

### Window Rules

XWayland applications receive:

- Rounded corners matching native windows
- Proper RGB format handling

---

## Customization

### Modifying the Username

Update the following variables:

```nix
username = "your-username";
homeDirectory = "/home/${username}";
```

### Adding a New Color Palette

Add a new entry to the `palettes` attribute set following the existing structure. Each palette must define all color attributes used by the theme system.

### Monitor Configuration

Modify the `monitors` attribute set:

```nix
monitors = {
  laptop = {
    name = "eDP-1";
    resolution = "2560x1600@165";
    position = "0x0";
    scale = "1";
  };
};
```

### Adding Custom Keybindings

Add entries to the `bind` list in the Hyprland settings:

```nix
bind = lib.flatten [
  # ... existing bindings
  [ "$mod, KEY, exec, command" ]
];
```

---

## Troubleshooting

### Theme Not Applying

1. Ensure the theme cache directory exists: `~/.cache/hypr/`
2. Check the current palette file: `cat ~/.cache/hypr/current-palette`
3. Restart Waybar: `killall waybar && waybar &`

### Screen Recording Not Working

1. Verify GPU Screen Recorder is installed
2. Check recording directories exist: `~/Videos/Recordings`, `~/Videos/Replays`
3. Review recording status: `~/.config/hypr/scripts/record.sh status`

### XWayland Applications Look Wrong

1. Verify cursor theme is set: `echo $XCURSOR_THEME`
2. Check cursor size: `echo $XCURSOR_SIZE`
3. Restart the application

### Gaming Performance Issues

1. Enable game mode: `Super + F9`
2. Verify gamemode daemon: `gamemoded -s`
3. Check MangoHUD: `Super + Shift + F9`

### Bluetooth Not Working

1. Verify `hasBluetooth = true` in feature flags
2. Check blueman-applet is running
3. Verify Bluetooth service: `systemctl status bluetooth`

---

## License

```
BSD 3-Clause License

Copyright (c) 2025, DeMoD LLC
All rights reserved.

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

---

## Project Information

- **Project:** DeMoD Workstation
- **Maintainer:** DeMoD LLC
- **Repository:** Part of the Oligarchy NixOS distribution
- **Configuration Version:** NixOS 25.11 / Home Manager

For additional documentation, refer to the inline comments within the configuration file.

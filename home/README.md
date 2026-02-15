# DeMoD Home Configuration

A production-ready, modular Nix home-manager configuration for Oligarchy NixOS.

## Overview

DeMoD is a comprehensive home-manager configuration designed for Hyprland Wayland
environments. It provides a fully themeable desktop with 8 color palettes,
modular architecture, and flexible feature flags for hardware and software
detection.

## Optional Configuration

This home configuration is **optional**. Oligarchy NixOS was designed to function
fully without it. This configuration exists for users who want:

- Custom theming and color palettes
- Personalized keybindings
- Additional helper scripts
- Modular configuration management

The base system provides a working desktop out of the box. This home config is for
personality and personalization only.

## Features

- **8 Theme Palettes**: demod, catppuccin, nord, rosepine, gruvbox, dracula, tokyo, phosphor
- **Runtime Theme Switching**: Switch themes without rebuilding
- **Hardware Detection**: Auto-detects battery, touchpad, backlight, bluetooth
- **Feature Flags**: Toggle dev tools, gaming, audio, DCF, AI stack
- **Modular Architecture**: Separate configs for packages, waybar, hyprland, apps, scripts
- **Flake-based**: Proper Nix flake with validation and assertions

## Quick Start

### Using Flakes

```nix
# In your flake.nix
{
  inputs.demod.url = "path:/path/to/home2";

  outputs = { self, demod, ... }: {
    homeConfigurations.x86_64-linux = demod.homeConfigurations.x86_64-linux;
  };
}
```

### Using NixOS Module

```nix
# In configuration.nix
imports = [ ./home2/flake.nix ];

programs.demod = {
  enable = true;
  username = "youruser";
  theme = "demod";
};
```

## Requirements

- NixOS 25.05 or newer
- Home Manager (built via flake)
- Hyprland (for Wayland) or X11 window manager

## Directory Structure

```
home2/
├── home.nix              # Main entry point with validation
├── flake.nix             # Nix flake with outputs
├── packages.nix          # Package installations
├── themes/
│   └── default.nix      # 8 color palettes
├── hyprland/
│   └── default.nix      # Hyprland window manager
├── waybar/
│   └── default.nix      # Status bar
├── terminal/
│   └── kitty.nix        # Terminal config
├── shell/
│   └── default.nix      # Bash configuration
├── apps/
│   ├── kde-globals.nix  # KDE theming
│   ├── gtk-theming.nix  # GTK theming
│   ├── wofi.nix         # App launcher
│   ├── wlogout.nix      # Power menu
│   ├── hyprlock.nix     # Screen lock
│   └── ...
├── scripts/
│   └── default.nix      # Helper scripts
└── x11/                 # Optional X11 configs
```

## Configuration

### Username

```nix
# Default: "asher"
home.nix.override { username = "yourname"; }
```

### Theme Selection

Choose from 8 built-in themes:

| Theme | Description |
|-------|-------------|
| demod | Turquoise/violet, white on black |
| catppuccin | Cozy pastel |
| nord | Arctic blue |
| rosepine | Rose/pine |
| gruvbox | Warm earthy |
| dracula | Purple classic |
| tokyo | Japanese night |
| phosphor | Retro terminal green |

### Feature Flags

Hardware detection runs at build time via `lib.pathExists`. Override any detected
value by providing your own:

```nix
features = {
  # Hardware (auto-detected)
  hasBattery = lib.pathExists "/sys/class/power_supply/BAT0";
  hasTouchpad = lib.pathExists "/dev/input/event0";
  hasBacklight = lib.pathExists "/sys/class/backlight";
  hasBluetooth = lib.pathExists "/sys/class/bluetooth";

  # Software
  enableDev = true;
  enableGaming = false;
  enableAudio = true;
  enableDCF = false;
  enableAIStack = false;

  # Session
  sessionType = "wayland";  # or "x11"
  x11Wm = "icewm";         # icewm, leftwm, dwm, plasma-x11
};
```

## Keybindings

### Core

| Key | Action |
|-----|--------|
| Super + / | Keybind help |
| Super + Return | Terminal |
| Super + Space | App launcher |
| Super + B | Browser |
| Super + E | File manager |

### Windows

| Key | Action |
|-----|--------|
| Super + Q | Close window |
| Super + W | Toggle float |
| Super + F | Fullscreen |
| Super + G | Toggle group |
| Super + H/J/K/L | Focus (vim keys) |

### Workspaces

| Key | Action |
|-----|--------|
| Super + 1-0 | Go to workspace |
| Super + S | Scratchpad |
| Super + Tab | Next in group |

### System

| Key | Action |
|-----|--------|
| Super + Print | Screenshot |
| Super + R | Toggle recording |
| Super + F8 | Cycle theme |
| Super + Escape | Power menu |
| Super + Ctrl + L | Lock screen |
| Super + T | Thermal status |

### Gaming (when enabled)

| Key | Action |
|-----|--------|
| Super + F9 | Toggle gamemode |
| Super + Shift + F9 | MangoHUD overlay |

## Validation

The configuration includes assertions to catch misconfigurations early:

- Username must be non-empty
- Theme must be valid
- Session type must be wayland or x11
- X11 window manager must be valid

## Building

```bash
# Using flake
sudo nixos-rebuild switch --flake .#

# Direct home-manager
home-manager switch --flake .#
```

## Modules

| Module | Description |
|--------|-------------|
| packages.nix | Fonts, CLI tools, applications |
| themes/ | Color palettes |
| hyprland/ | Window manager |
| waybar/ | Status bar |
| terminal/ | Kitty terminal |
| shell/ | Bash prompt and aliases |
| apps/ | KDE/Qt/GTK theming |
| scripts/ | Screenshot, volume, theme switching |
| x11/ | Optional X11 window managers |

## License

Copyright (c) 2024-2026 Asher LeRoy

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.

2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

3. Neither the name of the copyright holder nor the names of its contributors
   may be used to endorse or promote products derived from this software without
   specific prior written permission.

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

## Reference

Original monolithic configuration: `docs/asher.nix`

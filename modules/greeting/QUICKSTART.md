# Quick Start Guide

## Installation in 3 Steps

### 1. Add this flake to your NixOS configuration

In your `flake.nix`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    greeting.url = "path:/path/to/this/flake";  # Or use github: URL once published
  };

  outputs = { self, nixpkgs, greeting }: {
    nixosConfigurations.yourhostname = nixpkgs.lib.nixosSystem {
      modules = [
        greeting.nixosModules.greeting
        ./configuration.nix
      ];
    };
  };
}
```

### 2. Enable in configuration.nix

**Option A: Text greeting only**
```nix
{
  services.userGreeting.enable = true;
}
```

**Option B: Launch TUI on startup (Recommended)**
```nix
{
  services.userGreeting = {
    enable = true;
    tui.enable = true;
    tui.launchOnStartup = true;  # Interactive TUI on login
  };
}
```

**Option C: Text with TUI launcher**
```nix
{
  services.userGreeting = {
    enable = true;
    tui.enable = true;
    tui.showLauncher = true;  # Press any key to launch TUI
  };
}
```

### 3. Rebuild

```bash
sudo nixos-rebuild switch --flake .#yourhostname
```

## That's it!

Your greeting will now appear when you open a new terminal session.

## 🎨 What You Get

### Text Mode (Simple)
- Quick ASCII art banner
- System info (OS, kernel, uptime)
- Random helpful tip
- Links to resources

### TUI Mode (Interactive) 🆕
- Beautiful terminal UI with navigation
- Live system stats with memory usage
- Organized panels for info, links, tips
- Keyboard shortcuts (q=quit, r=refresh)
- Copy links with Ctrl+C
- Package search help

## Launch Manually Anytime

```bash
# Text greeting
show-greeting

# Interactive TUI
welcome-tui
```

## Quick Customization

### Change the welcome message

```nix
services.userGreeting.welcomeMessage = "Welcome to My NixOS!";
```

### Use your own ASCII art

```nix
services.userGreeting.asciiArt = ''
  ╔═══════════════╗
  ║  My Custom OS ║
  ╚═══════════════╝
'';
```

### Add company/project links

```nix
services.userGreeting.customLinks = [
  { name = "📚 Project Docs"; url = "https://docs.myproject.com"; }
  { name = "📊 Dashboard"; url = "https://dashboard.myproject.com"; }
];
```

## Disable the Greeting

In your shell profile (~/.bashrc, ~/.zshrc, etc.):

```bash
export GREETING_SHOWN=1
```

## Need More?

See the full README.md for all configuration options and TUI features!

# Quick Start Guide - Oligarchy Plymouth Theme

Get your retro-tech boot splash running in under 5 minutes.

## Method 1: Flake Module (Recommended)

### 1. Add to Your Flake

Edit your `flake.nix`:

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    oligarchy-plymouth.url = "path:/path/to/oligarchy-theme";
  };

  outputs = { nixpkgs, oligarchy-plymouth, ... }: {
    nixosConfigurations.yourhost = nixpkgs.lib.nixosSystem {
      modules = [
        oligarchy-plymouth.nixosModules.default
        {
          boot.plymouth.oligarchy.enable = true;
        }
      ];
    };
  };
}
```

### 2. Optional: Add Wallpaper

```bash
cp /path/to/your/image.jpg wallpaper.jpg
```

Then in your flake:
```nix
boot.plymouth.oligarchy = {
  enable = true;
  wallpaper = ./wallpaper.jpg;
};
```

### 3. Rebuild and Reboot

```bash
sudo nixos-rebuild switch --flake .#yourhost
sudo reboot
```

**Done!** See [FLAKE_USAGE.md](FLAKE_USAGE.md) for advanced options.

---

## Method 2: Traditional NixOS (Non-Flake)

### 1. Add to NixOS Configuration

**Optional: Add a custom wallpaper first**
```bash
# Copy your background image to the theme directory
cp /path/to/your/image.jpg oligarchy-theme/wallpaper.jpg
```

Edit `/etc/nixos/configuration.nix`:

```nix
{ config, pkgs, ... }:

let
  oligarchy-theme = pkgs.callPackage /path/to/oligarchy-theme/package.nix {};
in
{
  boot.plymouth = {
    enable = true;
    theme = "oligarchy";
    themePackages = [ oligarchy-theme ];
  };
  
  # Optional: Clean boot experience
  boot.kernelParams = [ "quiet" ];
  boot.consoleLogLevel = 3;
}
```

## 2. Rebuild System

```bash
sudo nixos-rebuild switch
```

## 3. Test It

```bash
# Quick test without rebooting
sudo plymouthd --debug --debug-file=/tmp/plymouth-debug.log
sudo plymouth --show-splash
sleep 5
sudo plymouth --quit

# Check for errors
cat /tmp/plymouth-debug.log
```

## 4. Reboot

```bash
sudo reboot
```

## That's It!

Your system will now boot with the Oligarchy DeMoD-themed splash screen.

## File Descriptions

- **oligarchy.script** - Main theme code (animation logic)
- **oligarchy.plymouth** - Theme definition file
- **default.nix** - Nix package definition
- **wallpaper.jpg.example** - Placeholder for custom background image (rename to wallpaper.jpg)
- **nixos-config-example.nix** - Configuration examples
- **README.md** - Full documentation
- **COLORS.md** - Complete color reference
- **DESIGN.md** - Visual design specification
- **WALLPAPER.md** - Custom wallpaper usage guide
- **CHANGELOG.md** - Version history
- **CODE_REVIEW.md** - Technical improvements
- **QUICKSTART.md** - This file

## Customization

Want to tweak the colors? Edit `oligarchy.script` lines 14-70:

```javascript
// Change accent from turquoise to violet
color.accent.r = 0.545;  // #8B5CF6
color.accent.g = 0.361;
color.accent.b = 0.965;
```

Then rebuild: `sudo nixos-rebuild switch`

## Troubleshooting

**Theme not showing?**
1. Check Plymouth is enabled: `systemctl status plymouth`
2. Verify theme is installed: `plymouth-set-default-theme --list`
3. Check logs: `/tmp/plymouth-debug.log`

**Colors look wrong?**
- Ensure your display supports RGB color
- Check color depth settings in your BIOS/UEFI

**Animation stuttering?**
- Update graphics drivers
- Check system performance during boot

## Support

See README.md for full documentation and advanced configuration options.
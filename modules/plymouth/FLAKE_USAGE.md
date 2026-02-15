# Using Oligarchy Plymouth Theme as a Nix Flake

This theme is available as a Nix flake with a NixOS module for easy integration.

## Quick Start with Flakes

### 1. Add to your flake.nix

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    
    oligarchy-plymouth = {
      url = "path:/path/to/oligarchy-theme";  # Or git URL when published
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs = { self, nixpkgs, oligarchy-plymouth, ... }: {
    nixosConfigurations.yourhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        oligarchy-plymouth.nixosModules.default
        
        {
          boot.plymouth.oligarchy.enable = true;
        }
      ];
    };
  };
}
```

### 2. Rebuild and reboot

```bash
sudo nixos-rebuild switch --flake .#yourhost
sudo reboot
```

## Module Options

The module provides several configuration options:

### `boot.plymouth.oligarchy.enable`

**Type**: `boolean`  
**Default**: `false`

Enable the Oligarchy Plymouth theme.

```nix
boot.plymouth.oligarchy.enable = true;
```

### `boot.plymouth.oligarchy.wallpaper`

**Type**: `null` or `path`  
**Default**: `null`

Path to a wallpaper image (JPEG recommended).

```nix
boot.plymouth.oligarchy = {
  enable = true;
  wallpaper = ./wallpaper.jpg;
};
```

### `boot.plymouth.oligarchy.overlayOpacity`

**Type**: `float` (0.0-1.0)  
**Default**: `0.5`

Dark overlay opacity for wallpaper mode.

```nix
boot.plymouth.oligarchy = {
  enable = true;
  wallpaper = ./wallpaper.jpg;
  overlayOpacity = 0.7;  # Darker overlay
};
```

**Note**: Currently requires manual script editing. A warning will guide you.

### `boot.plymouth.oligarchy.quiet`

**Type**: `boolean`  
**Default**: `true`

Enable quiet boot (hide kernel messages).

```nix
boot.plymouth.oligarchy = {
  enable = true;
  quiet = true;  # Clean boot experience
};
```

### `boot.plymouth.oligarchy.consoleLogLevel`

**Type**: `integer` (0-7)  
**Default**: `3`

Console log level during boot.

```nix
boot.plymouth.oligarchy = {
  enable = true;
  consoleLogLevel = 0;  # Maximum quiet
};
```

## Complete Configuration Examples

### Minimal (Solid Color Background)

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    oligarchy-plymouth.url = "path:/path/to/oligarchy-theme";
  };

  outputs = { nixpkgs, oligarchy-plymouth, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
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

### With Wallpaper

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    oligarchy-plymouth.url = "path:/path/to/oligarchy-theme";
  };

  outputs = { nixpkgs, oligarchy-plymouth, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        oligarchy-plymouth.nixosModules.default
        {
          boot.plymouth.oligarchy = {
            enable = true;
            wallpaper = ./assets/wallpaper.jpg;
            overlayOpacity = 0.6;
          };
        }
      ];
    };
  };
}
```

### Maximum Quiet Boot

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    oligarchy-plymouth.url = "path:/path/to/oligarchy-theme";
  };

  outputs = { nixpkgs, oligarchy-plymouth, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        oligarchy-plymouth.nixosModules.default
        {
          boot.plymouth.oligarchy = {
            enable = true;
            quiet = true;
            consoleLogLevel = 0;
          };
        }
      ];
    };
  };
}
```

### Full Featured

```nix
{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    oligarchy-plymouth.url = "path:/path/to/oligarchy-theme";
  };

  outputs = { nixpkgs, oligarchy-plymouth, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        oligarchy-plymouth.nixosModules.default
        {
          boot.plymouth.oligarchy = {
            enable = true;
            wallpaper = ./wallpaper.jpg;
            overlayOpacity = 0.7;
            quiet = true;
            consoleLogLevel = 3;
          };
        }
      ];
    };
  };
}
```

## Using with Home Manager

If you're using Home Manager, add the theme to your system configuration, not Home Manager:

```nix
# flake.nix
{
  outputs = { nixpkgs, home-manager, oligarchy-plymouth, ... }: {
    nixosConfigurations.myhost = nixpkgs.lib.nixosSystem {
      modules = [
        # System-level Plymouth configuration
        oligarchy-plymouth.nixosModules.default
        {
          boot.plymouth.oligarchy.enable = true;
        }
        
        # Home Manager
        home-manager.nixosModules.home-manager
        {
          home-manager.users.youruser = import ./home.nix;
        }
      ];
    };
  };
}
```

## Directory Structure

When using as a flake, your repository might look like:

```
my-nixos-config/
├── flake.nix
├── flake.lock
├── configuration.nix
├── hardware-configuration.nix
├── wallpaper.jpg              # Optional
└── oligarchy-theme/           # Git submodule or local copy
    ├── flake.nix
    ├── module.nix
    ├── package.nix
    ├── oligarchy.script
    └── ...
```

## Using from Git

Once published to a Git repository:

```nix
{
  inputs = {
    oligarchy-plymouth = {
      url = "github:yourusername/oligarchy-plymouth-theme";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
}
```

Or with a specific branch/tag:

```nix
{
  inputs = {
    oligarchy-plymouth = {
      url = "github:yourusername/oligarchy-plymouth-theme/v2.1";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
}
```

## Development Workflow

### Testing Changes

```bash
# Enter development shell
nix develop

# Test the theme
sudo plymouthd --debug
sudo plymouth --show-splash
sleep 5
sudo plymouth --quit

# Build the package
nix build

# Check flake
nix flake check
```

### Updating the Lock File

```bash
nix flake update
```

### Building for Different Systems

```bash
# Build for current system
nix build

# Build for specific system
nix build .#packages.aarch64-linux.oligarchy-plymouth-theme
```

## Troubleshooting

### Flake Not Found

```bash
# Make sure flake.nix exists
ls -la flake.nix

# Update flake lock
nix flake update
```

### Module Not Loading

```bash
# Check that module is imported
nix eval .#nixosConfigurations.yourhost.config.boot.plymouth.oligarchy.enable

# Should return: true
```

### Wallpaper Not Copying

Check activation scripts:

```bash
# View activation script
nixos-rebuild dry-activate --flake .#yourhost | grep oligarchy

# Check if wallpaper exists
ls -la /run/current-system/sw/share/plymouth/themes/oligarchy/wallpaper.jpg
```

### Using Old Configuration Method?

If you have an old configuration.nix style setup, you can still use the flake:

```nix
# In your existing configuration.nix
{ config, pkgs, ... }:

{
  imports = [
    # Import the module directly
    /path/to/oligarchy-theme/module.nix
  ];

  boot.plymouth.oligarchy = {
    enable = true;
    wallpaper = ./wallpaper.jpg;
  };
}
```

But using the flake input is recommended for better dependency management.

## Benefits of Using as a Flake

✅ **Reproducible**: Lock file ensures consistent builds  
✅ **Modular**: Clean NixOS module with options  
✅ **Updatable**: Easy to update with `nix flake update`  
✅ **Declarative**: All configuration in one place  
✅ **Type-safe**: Module options with validation  
✅ **Portable**: Share and reuse across systems  

## Migration from Non-Flake

If you're currently using the theme without flakes:

**Old way**:
```nix
boot.plymouth = {
  enable = true;
  theme = "oligarchy";
  themePackages = [ (pkgs.callPackage ./oligarchy-theme {}) ];
};
```

**New way**:
```nix
inputs.oligarchy-plymouth.url = "path:./oligarchy-theme";

# In modules:
boot.plymouth.oligarchy.enable = true;
```

## See Also

- **README.md** - General documentation
- **QUICKSTART.md** - Non-flake installation
- **WALLPAPER.md** - Wallpaper usage guide
- **module.nix** - Module implementation
- **flake.nix** - Flake definition
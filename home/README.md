# Modular Nix Home Configuration

A clean, modular organization of your NixOS home-manager configuration with themed components.

## 📁 Directory Structure

```
nix-home/
├── home.nix              # Main entry point
├── packages.nix          # Package installations & XDG config
├── themes/
│   └── default.nix      # Color palettes (DeMoD, Catppuccin, Nord, etc.)
├── waybar/
│   └── default.nix      # Waybar configuration & styling
├── hyprland/
│   └── default.nix      # Hyprland window manager config
├── shell/
│   └── default.nix      # Bash configuration & aliases
├── terminal/
│   └── default.nix      # Kitty terminal configuration
├── apps/
│   └── default.nix      # Application configs (mako, git, etc.)
├── scripts/
│   └── default.nix      # Helper scripts
└── README.md            # This file
```

##  Quick Start

1. **Copy to your config directory:**
   ```bash
   cp -r nix-home ~/.config/
   ```

2. **Update your flake or configuration to import:**
   ```nix
   # In your flake.nix or configuration.nix
   imports = [ ./nix-home/home.nix ];
   ```

3. **Customize settings in `home.nix`:**
   ```nix
   # Change active theme
   activePalette = "demod";  # or "catppuccin", "nord", "rosepine"
   
   # Toggle features
   features = {
     hasBattery = true;
     hasNumpad = true;
     enableDev = true;
     enableGaming = false;
     enableAudio = true;
   };
   ```

4. **Rebuild:**
   ```bash
   sudo nixos-rebuild switch --flake .
   # or
   home-manager switch --flake .
   ```

##  Theme System

### Available Themes
- **demod** - Radical retro-tech (turquoise/violet, white on black)
- **catppuccin** - Cozy pastel (Mocha variant)
- **nord** - Frozen and calm (arctic blue palette)
- **rosepine** - Elegant and muted (rose/pine)

### Switching Themes
Change the `activePalette` variable in `home.nix`:

```nix
activePalette = "nord";  # Switch to Nord theme
```

All components (waybar, kitty, hyprland, notifications) will automatically use the new theme.

### Adding New Themes
Add your palette to `themes/default.nix`:

```nix
palettes = {
  # ... existing palettes ...
  
  myTheme = {
    name = "My Theme";
    bg = "#000000";
    accent = "#FF00FF";
    # ... other colors
  };
};
```

## 📦 Module Overview

### `packages.nix`
- Font installations
- Hyprland ecosystem tools
- CLI utilities
- Desktop applications
- Development tools (conditional)
- Gaming tools (conditional)
- XDG directory configuration

### `waybar/`
- Status bar configuration
- Module layouts (conditional based on features)
- Themed styling
- Custom widgets

### `hyprland/`
- Window manager settings
- Monitor configuration
- Keybindings
- Animations & effects
- Window rules
- Environment variables

### `shell/`
- Bash prompt configuration
- Aliases
- Shell options
- FZF integration
- Themed welcome message

### `terminal/`
- Kitty terminal settings
- Font configuration
- Themed colors (ANSI palette)
- Tab bar styling

### `apps/`
- Mako notification daemon
- Git configuration
- Other app configs

### `scripts/`
- Screenshot utilities
- Volume control
- Brightness control (laptop)
- Lid event handler (laptop)
- System monitoring

## 🔧 Customization

### Feature Flags
Control what gets installed/configured via the `features` attribute:

```nix
features = {
  hasBattery = true;      # Laptop-specific features
  hasBluetooth = true;    # Bluetooth support
  hasTouchpad = true;     # Touchpad configuration
  hasBacklight = true;    # Brightness controls
  hasNumpad = true;       # Numpad keys
  enableDev = true;       # Development tools
  enableGaming = false;   # Gaming packages
  enableAudio = true;     # Audio tools
};
```

### Per-Module Customization
Each module can be edited independently:

- **Change packages:** Edit `packages.nix`
- **Modify keybindings:** Edit `hyprland/default.nix`
- **Customize waybar:** Edit `waybar/default.nix`
- **Add aliases:** Edit `shell/default.nix`
- **Tweak colors:** Edit `themes/default.nix`

### Monitor Configuration
Edit monitor settings in `hyprland/default.nix`:

```nix
monitors = {
  laptop = {
    name = "eDP-1";
    resolution = "1920x1080";
    position = "0x0";
    scale = "1";
  };
  # Add external monitors here
};
```

## 🔄 Migration from Original File

This modular structure was created from a single large `asher.nix` file. Key changes:

1. **Themes centralized** - All color palettes in one place
2. **Clear separation** - Each component has its own module
3. **Conditional features** - Easy to enable/disable features
4. **Better maintainability** - Easier to find and modify specific settings
5. **Reusable** - Theme system can be shared across configs

## 📝 Adding New Modules

To add a new module:

1. Create a new directory: `mkdir new-module`
2. Create `default.nix` with your configuration
3. Import it in `home.nix`:
   ```nix
   imports = [
     # ... existing imports ...
     ./new-module
   ];
   ```

## 🐛 Troubleshooting

### Theme not applying
- Ensure `activePalette` matches a palette name in `themes/default.nix`
- Rebuild your configuration
- Restart waybar: `pkill waybar && waybar &`

### Missing features
- Check `features` flags in `home.nix`
- Verify conditional packages are installed
- Check module imports

### Scripts not working
- Verify scripts have execute permissions
- Check script paths match
- Ensure required tools are installed

## 📚 Further Customization

This is a starting point - feel free to:
- Split large modules into multiple files
- Add new scripts
- Create custom waybar modules
- Add more theme palettes
- Create build variants for different machines

## Contributing

This configuration is personal, but feel free to use it as inspiration for your own modular NixOS setup!

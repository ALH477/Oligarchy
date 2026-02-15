# Oligarchy Plymouth Theme

A radical retro-tech Plymouth boot splash theme for Oligarchy NixOS, featuring the DeMoD color palette.

## Design Features

### DeMoD Palette Integration
- **Background**: Deep space (#080810) with subtle gradient overlay
- **Primary Accent**: Turquoise (#00F5D4) - used for logo, borders, progress
- **Secondary Accent**: Violet (#8B5CF6) - gradient transitions
- **Text**: Crisp white (#FFFFFF) and dimmed (#808080) variants
- **Surface Colors**: Layered depth with #101018 and #1C1C28

### Visual Elements
- **Animated Spinner**: 12-dot circular animation with turquoise-to-violet gradient transition
- **Smooth Progress Bar**: Turquoise accent with glow effect
- **Clean Typography**: Bold "OLIGARCHY" wordmark with subtle "NixOS" subtitle
- **Password Dialog**: Encrypted disk prompt with bordered overlay design
- **Gradient Background**: Subtle top-to-bottom fade for depth

### Technical Improvements
- Properly normalized RGB color values (0.0-1.0 range)
- Efficient sprite management and z-indexing
- Smooth animation timing and transitions
- Responsive layout using screen dimension calculations
- Clean, well-documented code structure

## Installation for NixOS

### Recommended: Flake Module (NixOS 23.05+)

The easiest way to use this theme is as a Nix flake module:

```nix
# flake.nix
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
          boot.plymouth.oligarchy = {
            enable = true;
            wallpaper = ./wallpaper.jpg;  # Optional
            quiet = true;
          };
        }
      ];
    };
  };
}
```

Then rebuild:
```bash
sudo nixos-rebuild switch --flake .#yourhost
```

**See [FLAKE_USAGE.md](FLAKE_USAGE.md) for complete flake documentation.**

### Traditional Installation (Non-Flake NixOS)

If you're not using flakes, you can still install the theme traditionally:

#### Adding a Custom Wallpaper (Optional)

The theme supports using a custom background wallpaper image:

1. **Add your wallpaper**:
   - Place a file named `wallpaper.jpg` in the `oligarchy-theme` directory
   - Recommended resolution: 1920x1080 or higher
   - Format: JPEG (for best compatibility with Plymouth)

2. **The theme will automatically**:
   - Scale the image to cover the entire screen
   - Maintain aspect ratio (may crop if aspect ratios don't match)
   - Add a dark overlay (50% opacity) for text contrast
   - Fall back to solid color if wallpaper is not found

3. **To remove wallpaper**:
   - Simply delete `wallpaper.jpg` from the theme directory
   - Theme will use the solid DeMoD color background

#### Method 1: Using NixOS Configuration (callPackage)

Add this to your `/etc/nixos/configuration.nix`:

```nix
{ config, pkgs, ... }:

let
  oligarchy-theme = pkgs.callPackage /path/to/oligarchy-theme/package.nix {};
in
{
  # Enable Plymouth
  boot.plymouth = {
    enable = true;
    theme = "oligarchy";
    themePackages = [ oligarchy-theme ];
  };
  
  # Optional: Clean boot
  boot.kernelParams = [ "quiet" ];
  boot.consoleLogLevel = 3;
}
```

**Note**: Using the flake module (see above) is recommended over this method.

#### Method 2: Manual Installation

1. Copy theme files to Plymouth themes directory:
```bash
sudo mkdir -p /usr/share/plymouth/themes/oligarchy
sudo cp oligarchy.plymouth /usr/share/plymouth/themes/oligarchy/
sudo cp oligarchy.script /usr/share/plymouth/themes/oligarchy/
```

2. Rebuild NixOS:
```bash
sudo nixos-rebuild switch
```

## File Structure

```
oligarchy-theme/
├── oligarchy.plymouth    # Theme definition
└── oligarchy.script      # Animation and display logic
```

## Customization

### Background Wallpaper

**Adding a wallpaper** (lines 76-123):
- Place `wallpaper.jpg` in the theme directory
- Image will be scaled to cover screen (maintaining aspect ratio)
- Dark overlay (50% opacity) applied automatically for text readability
- To adjust overlay darkness, edit line 106:
  ```javascript
  overlay_image = Image.Color(color.bg.r, color.bg.g, color.bg.b, 0.5, ...);
  //                                                            ^^^ 
  //                                                    Change this value (0.0-1.0)
  ```

### DeMoD Color Palette

Edit `oligarchy.script` to customize the DeMoD colors (RGB values normalized to 0-1):

**Background Colors** (lines 19-32):
```javascript
color.bg       // #080810 - Deep background
color.surface  // #101018 - Surface layer  
color.overlay  // #1C1C28 - Overlay/dialog background
```

**Accent Colors** (lines 35-43):
```javascript
color.accent   // #00F5D4 - Turquoise (primary)
color.violet   // #8B5CF6 - Violet (gradient)
```

**Text Colors** (lines 46-59):
```javascript
color.text     // #FFFFFF - Primary text
color.textAlt  // #E0E0E0 - Secondary text
color.textDim  // #808080 - Dimmed text
```

**Status Colors** (lines 62-70):
```javascript
color.success  // #39FF14 - Neon green
color.error    // #FF3B5C - Error red
```

### Animation Tuning

**Spinner Configuration** (lines 111-116):
```javascript
spinner.num_dots = 12;          // Number of dots (8-16 recommended)
spinner.radius = 35;            // Circle radius in pixels
spinner.rotation_speed = 1.8;   // Rotation speed multiplier
```

**Progress Bar** (lines 163-166):
```javascript
progress_bar.width = 450;   // Bar width in pixels
progress_bar.height = 3;    // Bar height (2-5 recommended)
```

### Typography

**Logo** (line 94):
```javascript
"Sans Bold 54"  // Font family and size
```

**Subtitle** (line 100):
```javascript
"Sans 18"       // Smaller size for subtitle
```

## Testing

Test the theme without rebooting:

```bash
sudo plymouthd --debug --debug-file=/tmp/plymouth-debug.log
sudo plymouth --show-splash
# Wait a few seconds to see the animation
sudo plymouth --quit
```

## Troubleshooting

If the theme doesn't appear:
1. Ensure Plymouth is enabled in your NixOS configuration
2. Check that files are in `/usr/share/plymouth/themes/oligarchy/`
3. Verify theme is selected: `plymouth-set-default-theme --list`
4. Check debug log: `/tmp/plymouth-debug.log`

## License

Free to use and modify.

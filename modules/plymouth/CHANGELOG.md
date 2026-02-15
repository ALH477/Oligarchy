# CHANGELOG - Oligarchy Plymouth Theme

## Version 3.0 - Flake Module (Current)

### Major Changes

#### Nix Flake Support
- **Added** complete flake.nix with proper inputs/outputs structure
- **Created** NixOS module (module.nix) with declarative options
- **Renamed** default.nix → package.nix for clarity
- **Added** flake.lock for reproducible builds
- **Implemented** module options for easy configuration

#### Module Options
- `boot.plymouth.oligarchy.enable` - Enable the theme
- `boot.plymouth.oligarchy.wallpaper` - Set wallpaper path
- `boot.plymouth.oligarchy.overlayOpacity` - Adjust overlay darkness
- `boot.plymouth.oligarchy.quiet` - Enable quiet boot
- `boot.plymouth.oligarchy.consoleLogLevel` - Set console verbosity

#### Development Experience
- **Added** development shell with Plymouth and ImageMagick
- **Added** formatter configuration (nixpkgs-fmt)
- **Multi-system** support (x86_64-linux, aarch64-linux)
- **Proper** flake outputs structure

#### Documentation
- **Created** FLAKE_USAGE.md - Comprehensive flake guide
- **Updated** README.md - Flake as primary installation method
- **Updated** QUICKSTART.md - Show flake first, traditional second
- **Updated** nixos-config-example.nix - Both methods shown
- **Created** FEATURES.md - Complete feature summary

### Technical Implementation

**Flake Structure:**
```
flake.nix           # Main flake definition
module.nix          # NixOS module with options
package.nix         # Package derivation (was default.nix)
flake.lock          # Lock file for reproducibility
```

**Module Integration:**
```nix
inputs.oligarchy-plymouth.nixosModules.default
# Provides: boot.plymouth.oligarchy.*
```

### Benefits

✅ **Declarative** - All options in one place  
✅ **Type-safe** - Module validates configuration  
✅ **Reproducible** - Lock file ensures consistency  
✅ **Modular** - Clean separation of concerns  
✅ **Portable** - Easy to share and reuse  
✅ **Updatable** - Simple `nix flake update`  

### Migration Path

**Old (callPackage)**:
```nix
boot.plymouth.themePackages = [ (pkgs.callPackage ./oligarchy-theme {}) ];
```

**New (flake module)**:
```nix
boot.plymouth.oligarchy.enable = true;
```

---

## Version 2.1 - Wallpaper Support

### New Features

#### Custom Background Wallpaper
- **Added** support for custom `wallpaper.jpg` background image
- **Automatic** scaling to cover screen with aspect ratio preservation
- **Smart** fallback to solid color if wallpaper not found
- **Overlay** system for text readability (50% dark overlay)
- **Center** positioning with proper offset calculations

#### Implementation Details
- Custom `max()` helper function for Plymouth compatibility
- Image scaling algorithm: `cover` style (similar to CSS)
- Graceful degradation if wallpaper fails to load
- Dark overlay (#080810 at 50% opacity) for consistent text contrast

#### Documentation
- **Added** WALLPAPER.md with comprehensive usage guide
- **Added** wallpaper.jpg.example as placeholder template
- **Updated** README.md with wallpaper installation instructions
- **Updated** default.nix to copy wallpaper.jpg if present

### Technical Changes
- Added wallpaper loading logic (lines 76-123 in script)
- Implemented automatic scaling with aspect ratio preservation
- Added conditional rendering: wallpaper mode vs solid color mode
- Updated Nix package to include optional wallpaper.jpg

---

## Version 2.0 - DeMoD Palette Integration

### Major Changes

#### Color System Overhaul
- **Replaced** generic blue/gold palette with official DeMoD Radical Retro-Tech Palette
- **Implemented** proper RGB normalization (0.0-1.0 range) for all colors
- **Added** full color palette definitions:
  - Background layers: `bg`, `surface`, `overlay`
  - Accents: `accent` (turquoise), `violet`  
  - Text variants: `text`, `textAlt`, `textDim`
  - Status colors: `success`, `error`

#### Visual Improvements
- **Enhanced** spinner animation:
  - Increased from 8 to 12 dots for smoother appearance
  - Added turquoise-to-violet gradient color transition
  - Implemented pulse effect with size variation
  - Improved trail fade algorithm
- **Added** background gradient overlay for depth
- **Upgraded** progress bar with glow effect
- **Redesigned** password dialog:
  - Turquoise border accents
  - Lock icon indicator
  - Better visual hierarchy
  - Proper opacity handling

#### Code Quality
- **Refactored** entire script with proper structure and comments
- **Added** comprehensive section headers for organization
- **Improved** variable naming conventions (e.g., `color.accent.r` instead of magic numbers)
- **Implemented** screen dimension caching for performance
- **Added** proper error checking and bounds validation
- **Defined** Math.PI constant for precision

#### Documentation
- **Updated** README with DeMoD palette details
- **Added** comprehensive customization guide
- **Improved** installation instructions
- **Added** detailed color reference with hex values
- **Created** this CHANGELOG

### Technical Improvements

**Color Management:**
```diff
- background_color.red = 0.08;
+ color.bg.r = 0.031;  // #080810
```

**Animation Quality:**
```diff
- spinner.num_dots = 8;
+ spinner.num_dots = 12;
+ // Added gradient transition and pulse effects
```

**Code Organization:**
```diff
- Scattered color definitions
+ Centralized color palette with semantic naming
+ Proper sectioning with header comments
+ Improved readability and maintainability
```

### Breaking Changes
None - Theme is backward compatible with existing NixOS configurations.

---

## Version 1.0 - Initial Release

### Features
- Basic Plymouth theme functionality
- Simple spinner animation  
- Progress bar
- Password dialog support
- Generic color scheme
# Wallpaper Background Guide

The Oligarchy Plymouth Theme supports custom background wallpapers with automatic scaling and overlay.

## Quick Start

1. **Add your wallpaper**:
   ```bash
   cp /path/to/your/image.jpg oligarchy-theme/wallpaper.jpg
   ```

2. **Rebuild NixOS**:
   ```bash
   sudo nixos-rebuild switch
   ```

3. **Reboot to see it**:
   ```bash
   sudo reboot
   ```

## Image Requirements

### Format
- **Required**: JPEG format (`wallpaper.jpg`)
- **Why JPEG**: Plymouth has best compatibility with JPEG images
- **NOT recommended**: PNG (may not load in all Plymouth versions)

### Resolution
- **Recommended**: 1920×1080 (Full HD) or higher
- **Minimum**: 1280×720
- **Maximum**: 3840×2160 (4K)
- **Aspect ratio**: Any - will be automatically scaled

### File Size
- **Recommended**: Under 2MB
- **Why**: Plymouth loads this into memory during boot
- **Tip**: Compress JPEGs to 85% quality for best balance

## How Scaling Works

The theme uses **cover** scaling (similar to CSS `background-size: cover`):

```
Your Image          Screen          Result
┌──────────┐       ┌──────┐        ┌──────┐
│          │       │      │        │▓▓▓▓▓▓│  Scaled to fill,
│  1920×   │  →    │1920× │   =    │▓▓▓▓▓▓│  may crop top/bottom
│  1200    │       │1080  │        │▓▓▓▓▓▓│  or left/right
└──────────┘       └──────┘        └──────┘
```

### Scaling Behavior

1. **Image is wider than screen**: Crops left/right, fits height
2. **Image is taller than screen**: Crops top/bottom, fits width
3. **Image matches aspect ratio**: Perfect fit, no cropping

**Example calculations**:
- Image: 1920×1080, Screen: 1920×1080 → No scaling needed
- Image: 2560×1440, Screen: 1920×1080 → Scaled to 1920×1080
- Image: 1600×900, Screen: 1920×1080 → Scaled to 1920×1080

## Dark Overlay

A semi-transparent dark overlay is automatically applied to ensure text readability:

```
Wallpaper         Overlay          Result
┌─────────┐      ┌─────────┐      ┌─────────┐
│  Photo  │  +   │░░░░░░░░░│  =   │ Photo   │
│         │      │░ 50% ░░░│      │ darker  │
│         │      │░░░░░░░░░│      │ legible │
└─────────┘      └─────────┘      └─────────┘
```

### Adjusting Overlay Darkness

Edit `oligarchy.script` line 106:

```javascript
// Current: 50% opacity
overlay_image = Image.Color(color.bg.r, color.bg.g, color.bg.b, 0.5, ...);

// Lighter overlay (30%)
overlay_image = Image.Color(color.bg.r, color.bg.g, color.bg.b, 0.3, ...);

// Darker overlay (70%)
overlay_image = Image.Color(color.bg.r, color.bg.g, color.bg.b, 0.7, ...);

// No overlay (not recommended - text may be unreadable)
overlay_image = Image.Color(color.bg.r, color.bg.g, color.bg.b, 0.0, ...);
```

## Image Preparation Tips

### Using ImageMagick

**Resize and optimize**:
```bash
# Resize to 1920x1080 and compress
convert input.jpg -resize 1920x1080^ -gravity center -extent 1920x1080 \
  -quality 85 wallpaper.jpg

# Just compress (keep original size)
convert input.jpg -quality 85 wallpaper.jpg
```

**Add blur effect** (for better text contrast):
```bash
convert input.jpg -blur 0x8 -quality 85 wallpaper.jpg
```

### Using GIMP

1. Open your image
2. **Image → Scale Image** → 1920×1080
3. **Filters → Blur → Gaussian Blur** (optional, ~5px radius)
4. **File → Export As** → `wallpaper.jpg`
5. Set quality to 85%

### Online Tools

- **Squoosh.app**: https://squoosh.app (compress JPEGs)
- **Photopea.com**: https://photopea.com (free Photoshop alternative)
- **Simple Image Resizer**: https://www.simpleimageresizer.com

## Recommended Wallpaper Styles

### ✅ Good Choices
- **Dark abstract patterns**: High contrast for bright text
- **Gradients**: Smooth backgrounds work well
- **Geometric patterns**: Professional, clean look
- **Space/tech imagery**: Fits the retro-tech aesthetic
- **Low-contrast textures**: Subtle backgrounds

### ❌ Avoid
- **Busy photographs**: Too distracting during boot
- **Bright images**: Makes text hard to read even with overlay
- **High-contrast patterns**: Can look chaotic
- **Images with text**: Confusing with theme text
- **Very detailed images**: Loses detail when overlaid

## Example: Creating a Gradient Wallpaper

```bash
# Create a dark gradient wallpaper with ImageMagick
convert -size 1920x1080 gradient:'#080810-#1C1C28' wallpaper.jpg

# Create a radial gradient
convert -size 1920x1080 radial-gradient:'#1C1C28-#080810' wallpaper.jpg

# Create a DeMoD-themed gradient
convert -size 1920x1080 gradient:'#080810-#00F5D4' -blur 0x100 wallpaper.jpg
```

## Fallback Behavior

If `wallpaper.jpg` is **not found** or **fails to load**:
- Theme automatically falls back to solid DeMoD color background
- Gradient overlay effect is applied instead
- No error messages shown to user
- Boot continues normally

This ensures the theme always works, even without a wallpaper.

## Troubleshooting

### Wallpaper Not Showing

**Check file exists**:
```bash
ls -lh /nix/store/*/share/plymouth/themes/oligarchy/wallpaper.jpg
```

**Verify it's a valid JPEG**:
```bash
file wallpaper.jpg
# Should say: JPEG image data
```

**Check Plymouth debug log**:
```bash
sudo plymouthd --debug --debug-file=/tmp/plymouth.log
sudo plymouth --show-splash
sleep 5
sudo plymouth --quit
grep -i "wallpaper\|image" /tmp/plymouth.log
```

### Wallpaper Looks Stretched or Cropped

This is normal behavior - the image is scaled to cover the screen:
- Change your wallpaper's aspect ratio to match your screen
- Or adjust the scaling in `oligarchy.script` lines 89-96

### Text Hard to Read

**Increase overlay darkness**:
```javascript
// Line 106 - increase from 0.5 to 0.7 or 0.8
overlay_image = Image.Color(color.bg.r, color.bg.g, color.bg.b, 0.7, ...);
```

**Or blur the wallpaper more**:
```bash
convert wallpaper.jpg -blur 0x10 wallpaper.jpg
```

### File Size Too Large

**Compress more aggressively**:
```bash
# Reduce quality to 75%
convert wallpaper.jpg -quality 75 wallpaper.jpg

# Or resize to 1280x720 for 720p displays
convert wallpaper.jpg -resize 1280x720 -quality 85 wallpaper.jpg
```

## Switching Between Wallpaper and Solid Color

**To use wallpaper**:
```bash
cp your-image.jpg oligarchy-theme/wallpaper.jpg
sudo nixos-rebuild switch
```

**To remove wallpaper**:
```bash
rm oligarchy-theme/wallpaper.jpg
sudo nixos-rebuild switch
```

The theme automatically detects the presence or absence of the file.

## Advanced: Animated Wallpapers

Plymouth theoretically supports animated backgrounds, but:
- **Not recommended**: Increases boot time
- **High memory usage**: Stores all frames
- **Complex setup**: Requires scripting frame changes
- **Better alternative**: Use a subtle static wallpaper

If you must, see Plymouth documentation on sprite animation.

## Best Practices

1. **Keep it simple**: Subtle backgrounds work best
2. **Test visibility**: Ensure text is readable
3. **Optimize file size**: Faster boot times
4. **Match your aesthetic**: Choose images that fit the DeMoD theme
5. **Have a backup plan**: Theme works without wallpaper too

## Example Wallpapers

Here are some concepts that work well:

**Dark Abstract**:
- Circuitry patterns on dark background
- Abstract tech wireframes
- Particle fields
- Matrix-style digital rain

**Gradients**:
- Turquoise to violet gradient
- Dark blue to black fade
- Radial glow effects

**Geometric**:
- Hexagonal grids
- Low-poly backgrounds
- Minimal line art

**Space/Sci-Fi**:
- Nebula clouds (darkened)
- Star fields
- Abstract space scenes
- Tron-style grids

All with dark color schemes to maintain the retro-tech aesthetic!
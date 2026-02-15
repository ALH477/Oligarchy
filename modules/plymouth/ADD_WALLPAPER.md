# Adding Your wallpaper.jpg File

## You Need to Provide This File

The Plymouth theme now supports custom wallpaper backgrounds, but **you need to add your own wallpaper.jpg file**.

## Quick Steps

1. **Get your image ready**:
   - Format: JPEG (.jpg)
   - Resolution: 1920×1080 or higher
   - Content: Dark/abstract works best

2. **Add it to the theme directory**:
   ```bash
   cp /path/to/your/image.jpg oligarchy-theme/wallpaper.jpg
   ```

3. **Deploy**:
   ```bash
   sudo nixos-rebuild switch
   sudo reboot
   ```

## If You Don't Have a Wallpaper Yet

**Option 1**: Skip it - the theme works great without a wallpaper using the solid DeMoD color background.

**Option 2**: Create a simple gradient:
```bash
# Install ImageMagick if needed
nix-shell -p imagemagick

# Create a dark gradient wallpaper
convert -size 1920x1080 gradient:'#080810-#1C1C28' wallpaper.jpg

# Or a radial gradient
convert -size 1920x1080 radial-gradient:'#1C1C28-#080810' wallpaper.jpg

# Or a DeMoD-themed turquoise gradient
convert -size 1920x1080 gradient:'#080810-#00F5D4' -blur 0x100 wallpaper.jpg
```

**Option 3**: Use a solid dark color:
```bash
# Create a solid dark background
convert -size 1920x1080 xc:'#080810' wallpaper.jpg
```

**Option 4**: Download free dark abstract wallpapers from:
- Unsplash.com (search: "dark abstract")
- Pexels.com (search: "dark technology")
- Wallhaven.cc (filter: dark, abstract)

## Current Status

Currently, there is **no wallpaper.jpg** in this theme directory. You have two choices:

1. **Add one**: Copy your image as `wallpaper.jpg`
2. **Don't add one**: Theme will use the beautiful DeMoD solid color background

Both look great! The wallpaper is entirely optional.

## What Happens Without wallpaper.jpg

The theme automatically falls back to:
- Deep space background (#080810)
- Subtle gradient overlay
- Same great animations and colors
- Zero errors or issues

## See Also

- **WALLPAPER.md** - Comprehensive wallpaper usage guide
- **wallpaper.jpg.example** - Placeholder with instructions
- **QUICKSTART.md** - Quick installation guide
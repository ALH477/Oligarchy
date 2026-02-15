# Oligarchy Plymouth Theme - Visual Design

This document describes the visual appearance of the boot splash theme.

## Layout Overview

### With Wallpaper

```
┌────────────────────────────────────────────────────────────┐
│ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│ ░░░[Your wallpaper.jpg with 50% dark overlay]░░░░░░░░░░░░ │
│ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│ ░░░░░░░░░░░░░░░░OLIGARCHY░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │ ← Turquoise (#00F5D4)
│ ░░░░░░░░░░░░░░░░░░NixOS░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │ ← Dimmed (#808080)
│ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│ ░░░░░░░░░░░░░░░░░░░◉ ◉░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│ ░░░░░░░░░░░░░░░░░◉     ◉░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │ ← Spinner
│ ░░░░░░░░░░░░░░░░░◉     ◉░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │   (Gradient animation)
│ ░░░░░░░░░░░░░░░░░░░◉ ◉░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│ ░░░░░░░░░░░░░────────────────────────░░░░░░░░░░░░░░░░░░░ │ ← Progress bar
│ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │   (Turquoise w/ glow)
│ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
│ ░Status message here░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │ ← Bottom-left
│ ░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░░ │
└────────────────────────────────────────────────────────────┘

Wallpaper: Your custom image (auto-scaled, centered)
Overlay: 50% dark overlay (#080810) for text contrast
```

### Without Wallpaper (Solid Color)

```
┌────────────────────────────────────────────────────────────┐
│                                                            │
│                    [Gradient Fade]                         │
│                                                            │
│                                                            │
│                      OLIGARCHY                             │ ← Turquoise (#00F5D4)
│                        NixOS                               │ ← Dimmed (#808080)
│                                                            │
│                                                            │
│                         ◉ ◉                                │
│                       ◉     ◉                              │ ← Spinner
│                       ◉     ◉                              │   (Gradient animation)
│                         ◉ ◉                                │
│                                                            │
│                                                            │
│              ────────────────────────                      │ ← Progress bar
│                                                            │   (Turquoise w/ glow)
│                                                            │
│                                                            │
│                                                            │
│  Status message here                                       │ ← Bottom-left
│                                                            │
└────────────────────────────────────────────────────────────┘

Background: Deep space (#080810) with subtle gradient
```

## Component Details

### 1. Background (Two Modes)

#### Mode A: With Wallpaper (wallpaper.jpg present)
- **Image**: User-provided `wallpaper.jpg`
- **Scaling**: Cover (maintains aspect ratio, may crop edges)
- **Positioning**: Centered on screen
- **Overlay**: 50% opacity dark layer (#080810)
- **Purpose**: Personalized boot experience
- **Z-index**: -100 (wallpaper), -99 (overlay)

#### Mode B: Solid Color (fallback)
- **Base Color**: `#080810` (Near-black with blue tint)
- **Gradient Overlay**: Top third fades from `#101018` to transparent
- **Effect**: Adds depth without being distracting
- **Z-index**: -100 to -99

**Automatic switching**: Theme detects wallpaper.jpg and chooses appropriate mode

### 2. Logo ("OLIGARCHY")
- **Font**: Sans Bold 54pt
- **Color**: `#00F5D4` (Bright turquoise)
- **Position**: Centered, ~120px above center
- **Effect**: High contrast against dark background
- **Purpose**: Strong brand presence

### 3. Subtitle ("NixOS")
- **Font**: Sans 18pt
- **Color**: `#808080` (Mid-gray)
- **Position**: Centered, ~60px above center
- **Effect**: Subtle, non-competing with main logo
- **Purpose**: Platform identification

### 4. Animated Spinner
- **Style**: 12-dot circular animation
- **Radius**: 35px
- **Position**: Centered, 40px below center
- **Animation**:
  - Rotation speed: 1.8× time
  - Color gradient: Turquoise → Violet
  - Size pulse: 4-8px with sinusoidal variation
  - Fade trail: 0.2-1.0 opacity
- **Effect**: Smooth, mesmerizing rotation
- **Z-index**: 10

### 5. Progress Bar
- **Dimensions**: 450px × 3px
- **Position**: Centered, 110px below center
- **Background**: `#101018` at 80% opacity
- **Foreground**: `#00F5D4` (Turquoise)
- **Glow**: Matching color at 30% opacity, 7px tall
- **Effect**: Clean, modern progress indication
- **Z-index**: 5 (bg), 10 (fg), 8 (glow)

### 6. Status Messages
- **Font**: Sans 11pt
- **Color**: `#E0E0E0` (Light gray)
- **Position**: Bottom-left, 40px from bottom, 20px from left
- **Purpose**: System status updates
- **Z-index**: 10000 (always on top)

### 7. Password Dialog (Encrypted Disk)
```
┌──────────────────────────────────────────┐ ← Turquoise border
│                                          │
│  🔒  Enter Password:                     │ ← Lock icon + prompt
│                                          │
│      ● ● ● ● ●                           │ ← Password bullets
│                                          │
│                                          │
└──────────────────────────────────────────┘ ← Turquoise border
```

- **Dimensions**: 500px × 140px
- **Background**: `#1C1C28` at 95% opacity
- **Border**: 2px `#00F5D4` (top & bottom)
- **Lock Icon**: 24×24px turquoise square
- **Prompt Font**: Sans Bold 13pt, white
- **Bullets**: `●` in turquoise, 14pt
- **Z-index**: 10000-10002

## Color Transitions

### Spinner Gradient Animation
The spinner creates a smooth gradient as it rotates:

```
Dot 1:  ●  #00F5D4 (Turquoise) ──────┐
Dot 2:  ●  #15F3D7                   │
Dot 3:  ●  #2BF1DA                   │
Dot 4:  ●  #40EFDD                   │ Gradient
Dot 5:  ●  #56ECE0                   │ Transition
Dot 6:  ●  #6BE9E3                   │
Dot 7:  ●  #81E7E6                   │
Dot 8:  ●  #96E4E9                   │
Dot 9:  ●  #ACE1EC                   │
Dot 10: ●  #C1DFEF                   │
Dot 11: ●  #D7DCF2                   │
Dot 12: ●  #8B5CF6 (Violet) ─────────┘
```

Each dot also has:
- **Alpha fade**: Creates trailing effect
- **Size pulse**: 4-8px sinusoidal variation
- **Continuous rotation**: Smooth, never stopping

## Animation Timing

- **Spinner rotation**: ~0.56 seconds per full revolution
- **Progress bar**: Updates on boot progress callbacks
- **Refresh rate**: 60 FPS (Plymouth default)
- **Gradient interpolation**: Linear between colors

## Visual Hierarchy

1. **Primary Focus**: "OLIGARCHY" logo (brightest turquoise)
2. **Secondary**: Animated spinner (gradient, movement)
3. **Tertiary**: Progress bar (functional indicator)
4. **Quaternary**: "NixOS" subtitle (subdued)
5. **Background**: Messages (informational only)

## Design Principles

- **High Contrast**: Bright accents on dark background
- **Minimal Distraction**: Clean, purposeful elements
- **Brand Consistency**: DeMoD palette throughout
- **Professional Polish**: Smooth animations, proper spacing
- **Accessibility**: Clear text, adequate color contrast
- **Retro-Tech Aesthetic**: Neon colors, digital styling

## Screen Adaptivity

The theme automatically adapts to screen dimensions:

```javascript
screen.width = Window.GetWidth();
screen.height = Window.GetHeight();
screen.half_width = screen.width / 2;
screen.half_height = screen.height / 2;
```

All elements are positioned relative to center, ensuring proper display on:
- 1920×1080 (Full HD)
- 2560×1440 (2K)
- 3840×2160 (4K)
- Ultra-wide displays
- Portrait orientations (tablets, rotated displays)

## Performance Considerations

- **Efficient rendering**: Only 12 sprites for spinner
- **Minimal redraws**: Only spinner animates continuously
- **Optimized gradients**: Pre-calculated per frame
- **Z-index optimization**: Proper layering for GPU acceleration
- **Memory footprint**: ~100KB total (extremely lightweight)
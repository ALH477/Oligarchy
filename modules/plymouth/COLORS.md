# DeMoD Color Palette Reference

Complete color mapping for the Oligarchy Plymouth Theme using the DeMoD Radical Retro-Tech Palette.

## Background Colors

### bg - Deep Background
- **Hex**: `#080810`
- **RGB**: `8, 8, 16`
- **Normalized**: `0.031, 0.031, 0.063`
- **Usage**: Primary background, deepest layer
- **Script**: `color.bg.r`, `color.bg.g`, `color.bg.b`

### surface - Surface Layer
- **Hex**: `#101018`
- **RGB**: `16, 16, 24`
- **Normalized**: `0.063, 0.063, 0.094`
- **Usage**: Progress bar background, gradient overlay
- **Script**: `color.surface.r`, `color.surface.g`, `color.surface.b`

### overlay - Overlay/Dialog
- **Hex**: `#1C1C28`
- **RGB**: `28, 28, 40`
- **Normalized**: `0.110, 0.110, 0.157`
- **Usage**: Password dialog background
- **Script**: `color.overlay.r`, `color.overlay.g`, `color.overlay.b`

## Accent Colors

### accent - Turquoise (Primary)
- **Hex**: `#00F5D4`
- **RGB**: `0, 245, 212`
- **Normalized**: `0.000, 0.961, 0.831`
- **Usage**: Logo, borders, progress bar, spinner (start)
- **Script**: `color.accent.r`, `color.accent.g`, `color.accent.b`
- **Glow**: `0 0 20px rgba(0, 245, 212, 0.3)`

### violet - Violet (Secondary)
- **Hex**: `#8B5CF6`
- **RGB**: `139, 92, 246`
- **Normalized**: `0.545, 0.361, 0.965`
- **Usage**: Gradient transitions, spinner (end)
- **Script**: `color.violet.r`, `color.violet.g`, `color.violet.b`
- **Glow**: `0 0 20px rgba(139, 92, 246, 0.3)`

## Text Colors

### text - Primary Text
- **Hex**: `#FFFFFF`
- **RGB**: `255, 255, 255`
- **Normalized**: `1.000, 1.000, 1.000`
- **Usage**: Password prompt, main text
- **Script**: `color.text.r`, `color.text.g`, `color.text.b`

### textAlt - Secondary Text
- **Hex**: `#E0E0E0`
- **RGB**: `224, 224, 224`
- **Normalized**: `0.878, 0.878, 0.878`
- **Usage**: Status messages
- **Script**: `color.textAlt.r`, `color.textAlt.g`, `color.textAlt.b`

### textDim - Dimmed Text
- **Hex**: `#808080`
- **RGB**: `128, 128, 128`
- **Normalized**: `0.502, 0.502, 0.502`
- **Usage**: Subtitle text ("NixOS")
- **Script**: `color.textDim.r`, `color.textDim.g`, `color.textDim.b`

## Status Colors

### success - Neon Green
- **Hex**: `#39FF14`
- **RGB**: `57, 255, 20`
- **Normalized**: `0.224, 1.000, 0.078`
- **Usage**: Success indicators (reserved for future use)
- **Script**: `color.success.r`, `color.success.g`, `color.success.b`

### error - Error Red
- **Hex**: `#FF3B5C`
- **RGB**: `255, 59, 92`
- **Normalized**: `1.000, 0.231, 0.361`
- **Usage**: Error indicators (reserved for future use)
- **Script**: `color.error.r`, `color.error.g`, `color.error.b`

## Gradient Effect

The theme uses a gradient transition from **turquoise to violet** in the spinner animation:

```javascript
// Color interpolation
color_mix = progress / spinner.num_dots;
dot_r = color.accent.r + (color.violet.r - color.accent.r) * color_mix;
dot_g = color.accent.g + (color.violet.g - color.accent.g) * color_mix;
dot_b = color.accent.b + (color.violet.b - color.accent.b) * color_mix;
```

**Gradient Angle**: 135deg (diagonal, bottom-left to top-right)

## Color Conversion Reference

To convert hex to normalized RGB (for Plymouth):

```python
def hex_to_normalized(hex_color):
    # Remove '#' if present
    hex_color = hex_color.lstrip('#')
    
    # Convert to RGB
    r = int(hex_color[0:2], 16)
    g = int(hex_color[2:4], 16)
    b = int(hex_color[4:6], 16)
    
    # Normalize to 0-1 range
    return (r/255, g/255, b/255)

# Example
hex_to_normalized("#00F5D4")  # Returns (0.000, 0.961, 0.831)
```

## Additional DeMoD Colors (Not Currently Used)

For future enhancements, these colors are also available in the DeMoD palette:

- **bgAlt**: `#0C0C14`
- **surfaceAlt**: `#161620`
- **border**: `#252530`
- **borderFocus**: `#00F5D4` (same as accent)
- **borderHover**: `#8B5CF6` (same as violet)
- **warning**: `#FFE814`
- **info**: `#00F5D4` (same as accent)
- **purple**: `#8B5CF6` (same as violet)
- **pink**: `#A78BFA`
- **orange**: `#FF9500`

## Usage in Script

All colors are centralized at the top of `oligarchy.script` (lines 14-70) for easy customization:

```javascript
// Example: Change accent color to pink
color.accent.r = 0.655;  // #A78BFA
color.accent.g = 0.545;
color.accent.b = 0.980;
```

After changing colors, rebuild NixOS:
```bash
sudo nixos-rebuild switch
```
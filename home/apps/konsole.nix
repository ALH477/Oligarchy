{ config, pkgs, lib, theme ? {}, ... }:

let
  p = theme;
  
  # Convert hex to RGB for KDE
  hexToRgb = hex: let
    hex' = lib.removePrefix "#" hex;
    r = lib.substring 0 2 hex';
    g = lib.substring 2 2 hex';
    b = lib.substring 4 2 hex';
    toDec = s: lib.toIntBase16 s;
  in "${toString (toDec r)},${toString (toDec g)},${toString (toDec b)}";
in
{
  # ════════════════════════════════════════════════════════════════════════════
  # Konsole Terminal Color Schemes - All 8 Themes
  # ════════════════════════════════════════════════════════════════════════════
  
  # DeMoD Theme
  home.file.".local/share/konsole/demod.colorscheme".text = ''
    [Background]
    Color=${hexToRgb p.bg}
    
    [BackgroundFaint]
    Color=${hexToRgb p.bg}
    
    [BackgroundIntense]
    Color=${hexToRgb p.bgAlt}
    
    [Color0]
    Color=${hexToRgb p.black}
    
    [Color0Faint]
    Color=${hexToRgb p.black}
    
    [Color0Intense]
    Color=${hexToRgb p.brightBlack}
    
    [Color1]
    Color=${hexToRgb p.red}
    
    [Color1Faint]
    Color=${hexToRgb p.red}
    
    [Color1Intense]
    Color=${hexToRgb p.brightRed}
    
    [Color2]
    Color=${hexToRgb p.green}
    
    [Color2Faint]
    Color=${hexToRgb p.green}
    
    [Color2Intense]
    Color=${hexToRgb p.brightGreen}
    
    [Color3]
    Color=${hexToRgb p.yellow}
    
    [Color3Faint]
    Color=${hexToRgb p.yellow}
    
    [Color3Intense]
    Color=${hexToRgb p.brightYellow}
    
    [Color4]
    Color=${hexToRgb p.blue}
    
    [Color4Faint]
    Color=${hexToRgb p.blue}
    
    [Color4Intense]
    Color=${hexToRgb p.brightBlue}
    
    [Color5]
    Color=${hexToRgb p.magenta}
    
    [Color5Faint]
    Color=${hexToRgb p.magenta}
    
    [Color5Intense]
    Color=${hexToRgb p.brightMagenta}
    
    [Color6]
    Color=${hexToRgb p.cyan}
    
    [Color6Faint]
    Color=${hexToRgb p.cyan}
    
    [Color6Intense]
    Color=${hexToRgb p.brightCyan}
    
    [Color7]
    Color=${hexToRgb p.white}
    
    [Color7Faint]
    Color=${hexToRgb p.white}
    
    [Color7Intense]
    Color=${hexToRgb p.brightWhite}
    
    [Foreground]
    Color=${hexToRgb p.text}
    
    [ForegroundFaint]
    Color=${hexToRgb p.textDim}
    
    [ForegroundIntense]
    Color=${hexToRgb p.brightWhite}
    
    [General]
    ColorScheme=${p.name}
    Description=${p.name} Dark Theme for Konsole
    Opacity=1
    Wallpaper=
  '';

  # Catppuccin Theme
  home.file.".local/share/konsole/catppuccin.colorscheme".text = ''
    [Background]
    Color=${hexToRgb p.bg}
    [BackgroundFaint]
    Color=${hexToRgb p.bg}
    [BackgroundIntense]
    Color=${hexToRgb p.bgAlt}
    [Color0]
    Color=${hexToRgb p.black}
    [Color0Faint]
    Color=${hexToRgb p.black}
    [Color0Intense]
    Color=${hexToRgb p.brightBlack}
    [Color1]
    Color=${hexToRgb p.red}
    [Color1Faint]
    Color=${hexToRgb p.red}
    [Color1Intense]
    Color=${hexToRgb p.brightRed}
    [Color2]
    Color=${hexToRgb p.green}
    [Color2Faint]
    Color=${hexToRgb p.green}
    [Color2Intense]
    Color=${hexToRgb p.brightGreen}
    [Color3]
    Color=${hexToRgb p.yellow}
    [Color3Faint]
    Color=${hexToRgb p.yellow}
    [Color3Intense]
    Color=${hexToRgb p.brightYellow}
    [Color4]
    Color=${hexToRgb p.blue}
    [Color4Faint]
    Color=${hexToRgb p.blue}
    [Color4Intense]
    Color=${hexToRgb p.brightBlue}
    [Color5]
    Color=${hexToRgb p.magenta}
    [Color5Faint]
    Color=${hexToRgb p.magenta}
    [Color5Intense]
    Color=${hexToRgb p.brightMagenta}
    [Color6]
    Color=${hexToRgb p.cyan}
    [Color6Faint]
    Color=${hexToRgb p.cyan}
    [Color6Intense]
    Color=${hexToRgb p.brightCyan}
    [Color7]
    Color=${hexToRgb p.white}
    [Color7Faint]
    Color=${hexToRgb p.white}
    [Color7Intense]
    Color=${hexToRgb p.brightWhite}
    [Foreground]
    Color=${hexToRgb p.text}
    [ForegroundFaint]
    Color=${hexToRgb p.textDim}
    [ForegroundIntense]
    Color=${hexToRgb p.brightWhite}
    [General]
    ColorScheme=${p.name}
    Description=${p.name} Dark Theme for Konsole
    Opacity=1
    Wallpaper=
  '';

  # Nord Theme
  home.file.".local/share/konsole/nord.colorscheme".text = ''
    [Background]
    Color=${hexToRgb p.bg}
    [BackgroundFaint]
    Color=${hexToRgb p.bg}
    [BackgroundIntense]
    Color=${hexToRgb p.bgAlt}
    [Color0]
    Color=${hexToRgb p.black}
    [Color0Faint]
    Color=${hexToRgb p.black}
    [Color0Intense]
    Color=${hexToRgb p.brightBlack}
    [Color1]
    Color=${hexToRgb p.red}
    [Color1Faint]
    Color=${hexToRgb p.red}
    [Color1Intense]
    Color=${hexToRgb p.brightRed}
    [Color2]
    Color=${hexToRgb p.green}
    [Color2Faint]
    Color=${hexToRgb p.green}
    [Color2Intense]
    Color=${hexToRgb p.brightGreen}
    [Color3]
    Color=${hexToRgb p.yellow}
    [Color3Faint]
    Color=${hexToRgb p.yellow}
    [Color3Intense]
    Color=${hexToRgb p.brightYellow}
    [Color4]
    Color=${hexToRgb p.blue}
    [Color4Faint]
    Color=${hexToRgb p.blue}
    [Color4Intense]
    Color=${hexToRgb p.brightBlue}
    [Color5]
    Color=${hexToRgb p.magenta}
    [Color5Faint]
    Color=${hexToRgb p.magenta}
    [Color5Intense]
    Color=${hexToRgb p.brightMagenta}
    [Color6]
    Color=${hexToRgb p.cyan}
    [Color6Faint]
    Color=${hexToRgb p.cyan}
    [Color6Intense]
    Color=${hexToRgb p.brightCyan}
    [Color7]
    Color=${hexToRgb p.white}
    [Color7Faint]
    Color=${hexToRgb p.white}
    [Color7Intense]
    Color=${hexToRgb p.brightWhite}
    [Foreground]
    Color=${hexToRgb p.text}
    [ForegroundFaint]
    Color=${hexToRgb p.textDim}
    [ForegroundIntense]
    Color=${hexToRgb p.brightWhite}
    [General]
    ColorScheme=${p.name}
    Description=${p.name} Dark Theme for Konsole
    Opacity=1
    Wallpaper=
  '';

  # Rosé Pine Theme
  home.file.".local/share/konsole/rosepine.colorscheme".text = ''
    [Background]
    Color=${hexToRgb p.bg}
    [BackgroundFaint]
    Color=${hexToRgb p.bg}
    [BackgroundIntense]
    Color=${hexToRgb p.bgAlt}
    [Color0]
    Color=${hexToRgb p.black}
    [Color0Faint]
    Color=${hexToRgb p.black}
    [Color0Intense]
    Color=${hexToRgb p.brightBlack}
    [Color1]
    Color=${hexToRgb p.red}
    [Color1Faint]
    Color=${hexToRgb p.red}
    [Color1Intense]
    Color=${hexToRgb p.brightRed}
    [Color2]
    Color=${hexToRgb p.green}
    [Color2Faint]
    Color=${hexToRgb p.green}
    [Color2Intense]
    Color=${hexToRgb p.brightGreen}
    [Color3]
    Color=${hexToRgb p.yellow}
    [Color3Faint]
    Color=${hexToRgb p.yellow}
    [Color3Intense]
    Color=${hexToRgb p.brightYellow}
    [Color4]
    Color=${hexToRgb p.blue}
    [Color4Faint]
    Color=${hexToRgb p.blue}
    [Color4Intense]
    Color=${hexToRgb p.brightBlue}
    [Color5]
    Color=${hexToRgb p.magenta}
    [Color5Faint]
    Color=${hexToRgb p.magenta}
    [Color5Intense]
    Color=${hexToRgb p.brightMagenta}
    [Color6]
    Color=${hexToRgb p.cyan}
    [Color6Faint]
    Color=${hexToRgb p.cyan}
    [Color6Intense]
    Color=${hexToRgb p.brightCyan}
    [Color7]
    Color=${hexToRgb p.white}
    [Color7Faint]
    Color=${hexToRgb p.white}
    [Color7Intense]
    Color=${hexToRgb p.brightWhite}
    [Foreground]
    Color=${hexToRgb p.text}
    [ForegroundFaint]
    Color=${hexToRgb p.textDim}
    [ForegroundIntense]
    Color=${hexToRgb p.brightWhite}
    [General]
    ColorScheme=${p.name}
    Description=${p.name} Dark Theme for Konsole
    Opacity=1
    Wallpaper=
  '';

  # Gruvbox Theme
  home.file.".local/share/konsole/gruvbox.colorscheme".text = ''
    [Background]
    Color=${hexToRgb p.bg}
    [BackgroundFaint]
    Color=${hexToRgb p.bg}
    [BackgroundIntense]
    Color=${hexToRgb p.bgAlt}
    [Color0]
    Color=${hexToRgb p.black}
    [Color0Faint]
    Color=${hexToRgb p.black}
    [Color0Intense]
    Color=${hexToRgb p.brightBlack}
    [Color1]
    Color=${hexToRgb p.red}
    [Color1Faint]
    Color=${hexToRgb p.red}
    [Color1Intense]
    Color=${hexToRgb p.brightRed}
    [Color2]
    Color=${hexToRgb p.green}
    [Color2Faint]
    Color=${hexToRgb p.green}
    [Color2Intense]
    Color=${hexToRgb p.brightGreen}
    [Color3]
    Color=${hexToRgb p.yellow}
    [Color3Faint]
    Color=${hexToRgb p.yellow}
    [Color3Intense]
    Color=${hexToRgb p.brightYellow}
    [Color4]
    Color=${hexToRgb p.blue}
    [Color4Faint]
    Color=${hexToRgb p.blue}
    [Color4Intense]
    Color=${hexToRgb p.brightBlue}
    [Color5]
    Color=${hexToRgb p.magenta}
    [Color5Faint]
    Color=${hexToRgb p.magenta}
    [Color5Intense]
    Color=${hexToRgb p.brightMagenta}
    [Color6]
    Color=${hexToRgb p.cyan}
    [Color6Faint]
    Color=${hexToRgb p.cyan}
    [Color6Intense]
    Color=${hexToRgb p.brightCyan}
    [Color7]
    Color=${hexToRgb p.white}
    [Color7Faint]
    Color=${hexToRgb p.white}
    [Color7Intense]
    Color=${hexToRgb p.brightWhite}
    [Foreground]
    Color=${hexToRgb p.text}
    [ForegroundFaint]
    Color=${hexToRgb p.textDim}
    [ForegroundIntense]
    Color=${hexToRgb p.brightWhite}
    [General]
    ColorScheme=${p.name}
    Description=${p.name} Dark Theme for Konsole
    Opacity=1
    Wallpaper=
  '';

  # Dracula Theme
  home.file.".local/share/konsole/dracula.colorscheme".text = ''
    [Background]
    Color=${hexToRgb p.bg}
    [BackgroundFaint]
    Color=${hexToRgb p.bg}
    [BackgroundIntense]
    Color=${hexToRgb p.bgAlt}
    [Color0]
    Color=${hexToRgb p.black}
    [Color0Faint]
    Color=${hexToRgb p.black}
    [Color0Intense]
    Color=${hexToRgb p.brightBlack}
    [Color1]
    Color=${hexToRgb p.red}
    [Color1Faint]
    Color=${hexToRgb p.red}
    [Color1Intense]
    Color=${hexToRgb p.brightRed}
    [Color2]
    Color=${hexToRgb p.green}
    [Color2Faint]
    Color=${hexToRgb p.green}
    [Color2Intense]
    Color=${hexToRgb p.brightGreen}
    [Color3]
    Color=${hexToRgb p.yellow}
    [Color3Faint]
    Color=${hexToRgb p.yellow}
    [Color3Intense]
    Color=${hexToRgb p.brightYellow}
    [Color4]
    Color=${hexToRgb p.blue}
    [Color4Faint]
    Color=${hexToRgb p.blue}
    [Color4Intense]
    Color=${hexToRgb p.brightBlue}
    [Color5]
    Color=${hexToRgb p.magenta}
    [Color5Faint]
    Color=${hexToRgb p.magenta}
    [Color5Intense]
    Color=${hexToRgb p.brightMagenta}
    [Color6]
    Color=${hexToRgb p.cyan}
    [Color6Faint]
    Color=${hexToRgb p.cyan}
    [Color6Intense]
    Color=${hexToRgb p.brightCyan}
    [Color7]
    Color=${hexToRgb p.white}
    [Color7Faint]
    Color=${hexToRgb p.white}
    [Color7Intense]
    Color=${hexToRgb p.brightWhite}
    [Foreground]
    Color=${hexToRgb p.text}
    [ForegroundFaint]
    Color=${hexToRgb p.textDim}
    [ForegroundIntense]
    Color=${hexToRgb p.brightWhite}
    [General]
    ColorScheme=${p.name}
    Description=${p.name} Dark Theme for Konsole
    Opacity=1
    Wallpaper=
  '';

  # Tokyo Night Theme
  home.file.".local/share/konsole/tokyo.colorscheme".text = ''
    [Background]
    Color=${hexToRgb p.bg}
    [BackgroundFaint]
    Color=${hexToRgb p.bg}
    [BackgroundIntense]
    Color=${hexToRgb p.bgAlt}
    [Color0]
    Color=${hexToRgb p.black}
    [Color0Faint]
    Color=${hexToRgb p.black}
    [Color0Intense]
    Color=${hexToRgb p.brightBlack}
    [Color1]
    Color=${hexToRgb p.red}
    [Color1Faint]
    Color=${hexToRgb p.red}
    [Color1Intense]
    Color=${hexToRgb p.brightRed}
    [Color2]
    Color=${hexToRgb p.green}
    [Color2Faint]
    Color=${hexToRgb p.green}
    [Color2Intense]
    Color=${hexToRgb p.brightGreen}
    [Color3]
    Color=${hexToRgb p.yellow}
    [Color3Faint]
    Color=${hexToRgb p.yellow}
    [Color3Intense]
    Color=${hexToRgb p.brightYellow}
    [Color4]
    Color=${hexToRgb p.blue}
    [Color4Faint]
    Color=${hexToRgb p.blue}
    [Color4Intense]
    Color=${hexToRgb p.brightBlue}
    [Color5]
    Color=${hexToRgb p.magenta}
    [Color5Faint]
    Color=${hexToRgb p.magenta}
    [Color5Intense]
    Color=${hexToRgb p.brightMagenta}
    [Color6]
    Color=${hexToRgb p.cyan}
    [Color6Faint]
    Color=${hexToRgb p.cyan}
    [Color6Intense]
    Color=${hexToRgb p.brightCyan}
    [Color7]
    Color=${hexToRgb p.white}
    [Color7Faint]
    Color=${hexToRgb p.white}
    [Color7Intense]
    Color=${hexToRgb p.brightWhite}
    [Foreground]
    Color=${hexToRgb p.text}
    [ForegroundFaint]
    Color=${hexToRgb p.textDim}
    [ForegroundIntense]
    Color=${hexToRgb p.brightWhite}
    [General]
    ColorScheme=${p.name}
    Description=${p.name} Dark Theme for Konsole
    Opacity=1
    Wallpaper=
  '';

  # Phosphor Theme
  home.file.".local/share/konsole/phosphor.colorscheme".text = ''
    [Background]
    Color=${hexToRgb p.bg}
    [BackgroundFaint]
    Color=${hexToRgb p.bg}
    [BackgroundIntense]
    Color=${hexToRgb p.bgAlt}
    [Color0]
    Color=${hexToRgb p.black}
    [Color0Faint]
    Color=${hexToRgb p.black}
    [Color0Intense]
    Color=${hexToRgb p.brightBlack}
    [Color1]
    Color=${hexToRgb p.red}
    [Color1Faint]
    Color=${hexToRgb p.red}
    [Color1Intense]
    Color=${hexToRgb p.brightRed}
    [Color2]
    Color=${hexToRgb p.green}
    [Color2Faint]
    Color=${hexToRgb p.green}
    [Color2Intense]
    Color=${hexToRgb p.brightGreen}
    [Color3]
    Color=${hexToRgb p.yellow}
    [Color3Faint]
    Color=${hexToRgb p.yellow}
    [Color3Intense]
    Color=${hexToRgb p.brightYellow}
    [Color4]
    Color=${hexToRgb p.blue}
    [Color4Faint]
    Color=${hexToRgb p.blue}
    [Color4Intense]
    Color=${hexToRgb p.brightBlue}
    [Color5]
    Color=${hexToRgb p.magenta}
    [Color5Faint]
    Color=${hexToRgb p.magenta}
    [Color5Intense]
    Color=${hexToRgb p.brightMagenta}
    [Color6]
    Color=${hexToRgb p.cyan}
    [Color6Faint]
    Color=${hexToRgb p.cyan}
    [Color6Intense]
    Color=${hexToRgb p.brightCyan}
    [Color7]
    Color=${hexToRgb p.white}
    [Color7Faint]
    Color=${hexToRgb p.white}
    [Color7Intense]
    Color=${hexToRgb p.brightWhite}
    [Foreground]
    Color=${hexToRgb p.text}
    [ForegroundFaint]
    Color=${hexToRgb p.textDim}
    [ForegroundIntense]
    Color=${hexToRgb p.brightWhite}
    [General]
    ColorScheme=${p.name}
    Description=${p.name} Dark Theme for Konsole
    Opacity=1
    Wallpaper=
  '';
}

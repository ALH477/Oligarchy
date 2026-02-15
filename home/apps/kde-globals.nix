{ config, pkgs, lib, theme, ... }:

let
  p = theme;
  
  # Convert hex to KDE RGB format (R,G,B without commas)
  hexToKde = hex: let
    hex' = lib.removePrefix "#" hex;
    r = lib.substring 0 2 hex';
    g = lib.substring 2 2 hex';
    b = lib.substring 4 2 hex';
    toDec = s: lib.toIntBase16 s;
  in "${toString (toDec r)},${toString (toDec g)},${toString (toDec b)}";
in
{
  # ════════════════════════════════════════════════════════════════════════════
  # KDE Plasma Global Settings & Color Scheme
  # Theme-aware configuration matching the active palette
  # ════════════════════════════════════════════════════════════════════════════
  
  # Main KDE Global Settings & Color Scheme
  home.file.".config/kdeglobals".text = ''
    [General]
    ColorScheme=${p.name}
    Name=${p.name} Dark
    shadeSortColumn=true
    
    [ColorEffects:Disabled]
    Color=56,56,56
    ColorAmount=0
    ColorEffect=0
    ContrastAmount=0.65
    ContrastEffect=1
    IntensityAmount=0.1
    IntensityEffect=2
    
    [ColorEffects:Inactive]
    ChangeSelectionColor=true
    Color=112,111,110
    ColorAmount=0.025
    ColorEffect=2
    ContrastAmount=0.1
    ContrastEffect=2
    Enable=false
    IntensityAmount=0
    IntensityEffect=0
    
    [Colors:Button]
    BackgroundAlternate=${hexToKde p.surface}
    BackgroundNormal=${hexToKde p.surfaceAlt}
    DecorationFocus=${hexToKde p.accent}
    DecorationHover=${hexToKde p.purple}
    ForegroundActive=${hexToKde p.accent}
    ForegroundInactive=${hexToKde p.textDim}
    ForegroundLink=${hexToKde p.accent}
    ForegroundNegative=${hexToKde p.error}
    ForegroundNeutral=${hexToKde p.warning}
    ForegroundNormal=${hexToKde p.text}
    ForegroundPositive=${hexToKde p.success}
    ForegroundVisited=${hexToKde p.pink}
    
    [Colors:Complementary]
    BackgroundAlternate=${hexToKde p.bg}
    BackgroundNormal=${hexToKde p.bg}
    DecorationFocus=${hexToKde p.accent}
    DecorationHover=${hexToKde p.purple}
    ForegroundActive=${hexToKde p.accent}
    ForegroundInactive=${hexToKde p.textDim}
    ForegroundLink=${hexToKde p.accent}
    ForegroundNegative=${hexToKde p.error}
    ForegroundNeutral=${hexToKde p.warning}
    ForegroundNormal=${hexToKde p.text}
    ForegroundPositive=${hexToKde p.success}
    ForegroundVisited=${hexToKde p.pink}
    
    [Colors:Header]
    BackgroundAlternate=${hexToKde p.bgAlt}
    BackgroundNormal=${hexToKde p.bg}
    DecorationFocus=${hexToKde p.accent}
    DecorationHover=${hexToKde p.purple}
    ForegroundActive=${hexToKde p.accent}
    ForegroundInactive=${hexToKde p.textDim}
    ForegroundLink=${hexToKde p.accent}
    ForegroundNegative=${hexToKde p.error}
    ForegroundNeutral=${hexToKde p.warning}
    ForegroundNormal=${hexToKde p.text}
    ForegroundPositive=${hexToKde p.success}
    ForegroundVisited=${hexToKde p.pink}
    
    [Colors:Selection]
    BackgroundAlternate=${hexToKde p.accentAlt}
    BackgroundNormal=${hexToKde p.accent}
    DecorationFocus=${hexToKde p.accent}
    DecorationHover=${hexToKde p.purple}
    ForegroundActive=${hexToKde p.textOnAccent}
    ForegroundInactive=${hexToKde p.textOnAccent}
    ForegroundLink=${hexToKde p.textOnAccent}
    ForegroundNegative=${hexToKde p.error}
    ForegroundNeutral=${hexToKde p.warning}
    ForegroundNormal=${hexToKde p.textOnAccent}
    ForegroundPositive=${hexToKde p.success}
    ForegroundVisited=${hexToKde p.pink}
    
    [Colors:Tooltip]
    BackgroundAlternate=${hexToKde p.surface}
    BackgroundNormal=${hexToKde p.bgAlt}
    DecorationFocus=${hexToKde p.accent}
    DecorationHover=${hexToKde p.purple}
    ForegroundActive=${hexToKde p.accent}
    ForegroundInactive=${hexToKde p.textDim}
    ForegroundLink=${hexToKde p.accent}
    ForegroundNegative=${hexToKde p.error}
    ForegroundNeutral=${hexToKde p.warning}
    ForegroundNormal=${hexToKde p.text}
    ForegroundPositive=${hexToKde p.success}
    ForegroundVisited=${hexToKde p.pink}
    
    [Colors:View]
    BackgroundAlternate=${hexToKde p.bgAlt}
    BackgroundNormal=${hexToKde p.bg}
    DecorationFocus=${hexToKde p.accent}
    DecorationHover=${hexToKde p.purple}
    ForegroundActive=${hexToKde p.accent}
    ForegroundInactive=${hexToKde p.textDim}
    ForegroundLink=${hexToKde p.accent}
    ForegroundNegative=${hexToKde p.error}
    ForegroundNeutral=${hexToKde p.warning}
    ForegroundNormal=${hexToKde p.text}
    ForegroundPositive=${hexToKde p.success}
    ForegroundVisited=${hexToKde p.pink}
    
    [Colors:Window]
    BackgroundAlternate=${hexToKde p.bgAlt}
    BackgroundNormal=${hexToKde p.bg}
    DecorationFocus=${hexToKde p.accent}
    DecorationHover=${hexToKde p.purple}
    ForegroundActive=${hexToKde p.accent}
    ForegroundInactive=${hexToKde p.textDim}
    ForegroundLink=${hexToKde p.accent}
    ForegroundNegative=${hexToKde p.error}
    ForegroundNeutral=${hexToKde p.warning}
    ForegroundNormal=${hexToKde p.text}
    ForegroundPositive=${hexToKde p.success}
    ForegroundVisited=${hexToKde p.pink}
    
    [Icons]
    Theme=Papirus-Dark
    
    [KDE]
    AnimationDurationFactor=0.5
    ShowDeleteCommand=true
    SingleClick=false
    contrast=4
    widgetStyle=kvantum
    
    [KFileDialog Settings]
    Allow Expansion=false
    Automatically select filename extension=true
    Breadcrumb Navigation=true
    Decoration position=2
    LocationCombo Coverage=
    Preview Width=80
    Show Bookmarks=true
    Show Full Path=false
    Show Preview=false
    Show Speedbar=true
    Show hidden files=false
    Sort by=Name
    Sort directories first=true
    Sort hidden files last=false
    Sort reversed=false
    Speedbar Width=130
    View Style=DetailTree
    
    [WM]
    activeBackground=${hexToKde p.bg}
    activeBlend=${hexToKde p.accent}
    activeForeground=${hexToKde p.text}
    inactiveBackground=${hexToKde p.bg}
    inactiveBlend=${hexToKde p.border}
    inactiveForeground=${hexToKde p.textDim}
  '';
}

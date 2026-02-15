{ config, pkgs, lib, theme, ... }:

let
  p = theme;
  
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
  # Plasma Color Scheme - Active Theme
  # ════════════════════════════════════════════════════════════════════════════
  
  home.file.".local/share/color-schemes/${p.name}.colors".text = ''
    [ColorEffects:Disabled]
    Color=56,56,56
    
    [ColorEffects:Inactive]
    ChangeSelectionColor=true
    Color=112,111,110
    
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
    
    [General]
    ColorScheme=${p.name}
    Name=${p.name} Dark
    ShadeSortColumn=true
    
    [Icons]
    Theme=Papirus-Dark
    
    [KDE]
    Contrast=4
    EffectDuration=0.25
    EffectStrength=1
    ForceAnimations=true
    MenuOpacity=95
    MenuShadow=5
    MenuBlend=0
    TooltipOpacity=90
    TooltipShadow=2
    ToolbarShadows=true
    ToolbarBlend=0
    AnimationsSpeed=1
    BlinkSpeed=10
    CursorSize=24
    CursorTheme=idTech4
    DoubleClickInterval=400
    FixedDragAllItems=false
    FixedDragItems=true
    IconTheme=Papirus-Dark
    KDE3WishGranted=true
    KDE4WishGranted=true
    LongPressDelay=500
    MenusHaveIcons=true
    PrimaryColor=${hexToKde p.accent}
    SecondaryColor=${hexToKde p.purple}
    ShadeHover=${hexToKde p.accent}
    ShowDeleteCommand=true
    ShowIconsOnPushButtons=true
    SidePanelIconSize=16
    SizeActionIconsVisible=true
    SpeedSliderWidth=14
    Style=kvantum
    SwapPrimaryAndSecondary=false
    ToolbarButtonStyle=0
    ToolbarIconSize=22
    ToolButtonStyle=4
    UnderlineLinks=false
    UserCreated=true
    WallpaperPluginEnabled=true
    WheelScrollLines=3
    X11Drag=all
  '';
}

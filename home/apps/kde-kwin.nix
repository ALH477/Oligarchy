{ config, pkgs, lib, theme, ... }:

{
  # ════════════════════════════════════════════════════════════════════════════
  # KWin Window Manager Configuration
  # ════════════════════════════════════════════════════════════════════════════
  
  home.file.".config/kwinrc".text = ''
    [Compositing]
    AnimationCurve=1
    AnimationSpeed=3
    Backend=OpenGL
    Enabled=true
    GLCore=true
    GLPreferBufferSwap=a
    GLTextureFilter=2
    HiddenPreviews=5
    OpenGLIsUnsafe=false
    WindowsBlockCompositing=true
    LatencyPolicy=Low
    AllowTearing=true
    
    [Effect-blur]
    BlurStrength=8
    NoiseStrength=4
    
    [Effect-overview]
    BorderActivate=9
    
    [Effect-windowview]
    BorderActivateAll=9
    
    [Plugins]
    blurEnabled=true
    contrastEnabled=true
    dimscreenEnabled=true
    fadeEnabled=true
    glideEnabled=false
    kwin4_effect_diminactiveEnabled=true
    kwin4_effect_squashEnabled=false
    magiclampEnabled=false
    scaleEnabled=true
    slideEnabled=true
    
    [TabBox]
    BorderActivate=9
    BorderAlternativeActivate=9
    LayoutName=thumbnail_grid
    
    [Tiling]
    padding=4
    
    [Windows]
    BorderlessMaximizedWindows=false
    ElectricBorderCooldown=350
    ElectricBorderCornerRatio=0.25
    ElectricBorderDelay=150
    ElectricBorderMaximize=true
    ElectricBorderTiling=true
    ElectricBorders=0
    FocusPolicy=ClickToFocus
    FocusStealingPreventionLevel=1
    
    [Xwayland]
    Scale=1
    XwaylandEavesdrops=Combinations
    XwaylandEavesdropsAllowed=true
    
    [NightColor]
    Active=true
    EveningBeginFixed=2000
    Mode=Times
    MorningBeginFixed=0600
    NightTemperature=4500
    
    [org.kde.kdecoration2]
    BorderSize=Normal
    BorderSizeAuto=false
    ButtonsOnLeft=XIA
    ButtonsOnRight=
    CloseOnDoubleClickOnMenu=false
    library=org.kde.breeze
    theme=Breeze
  '';
}

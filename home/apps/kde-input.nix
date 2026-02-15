{ config, pkgs, lib, theme, ... }:

{
  # ════════════════════════════════════════════════════════════════════════════
  # KDE Input Settings - Keyboard, Mouse, Touchpad, Cursor
  # ════════════════════════════════════════════════════════════════════════════
  
  home.file.".config/kcminputrc".text = ''
    [Keyboard]
    KeyRepeat=repeat
    RepeatDelay=300
    RepeatRate=50
    
    [Libinput][1][Apple Inc. Magic Trackpad]
    NaturalScroll=true
    PointerAcceleration=0
    TapToClick=true
    
    [Mouse]
    cursorTheme=idTech4
    cursorSize=24
    
    [Tmp]
    LeftHandedOverride=false
  '';
}

{ config, pkgs, lib, theme ? {}, ... }:

{
  # ════════════════════════════════════════════════════════════════════════════
  # Plasma Shell & Power Management Configuration
  # ════════════════════════════════════════════════════════════════════════════
  
  # Plasma Shell Settings
  home.file.".config/plasmarc".text = ''
    [Theme]
    name=breeze-dark
    
    [Wallpapers]
    usersWallpapers=
  '';

  # KDE Power Management - Gaming-friendly profiles
  home.file.".config/powerdevilrc".text = ''
    [AC][Performance]
    PowerProfile=performance
    
    [AC][Display]
    DimDisplayIdleTimeoutSec=600
    TurnOffDisplayIdleTimeoutSec=900
    
    [AC][SuspendAndShutdown]
    AutoSuspendAction=0
    AutoSuspendIdleTimeoutSec=0
    PowerButtonAction=16
    
    [Battery][BatteryCritical]
    BatteryCriticalAction=1
    
    [Battery][BatteryLow]
    BatteryLowAction=0
    
    [Battery][Performance]
    PowerProfile=balanced
    
    [Battery][Display]
    DimDisplayIdleTimeoutSec=120
    TurnOffDisplayIdleTimeoutSec=300
    
    [LowBattery][Performance]
    PowerProfile=power-saver
  '';

  # System Settings
  home.file.".config/kscreenlockerrc".text = ''
    [Daemon]
    Autolock=false
    LockOnResume=true
    LockOnStart=false
  '';
}

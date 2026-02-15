{ lib, ... }:

{
  # Required state version for home-manager
  home.stateVersion = "25.11";

  # Hardware Profile Definitions
  # Use these profiles based on your system type
  
  profiles = {
    # ═══════════════════════════════════════════════════════════════════════════
    # Laptop Profile
    # ═══════════════════════════════════════════════════════════════════════════
    laptop = {
      hasBattery = true;
      hasTouchpad = true;
      hasBacklight = true;
      hasBluetooth = true;
      hasNumpad = false;
      enableDev = true;
      enableGaming = false;
      enableAudio = true;
    };

    # ═══════════════════════════════════════════════════════════════════════════
    # Desktop Profile  
    # ═══════════════════════════════════════════════════════════════════════════
    desktop = {
      hasBattery = false;
      hasTouchpad = false;
      hasBacklight = false;
      hasBluetooth = false;
      hasNumpad = true;
      enableDev = true;
      enableGaming = true;
      enableAudio = true;
    };

    # ═══════════════════════════════════════════════════════════════════════════
    # Workstation Profile (high-end desktop)
    # ═══════════════════════════════════════════════════════════════════════════
    workstation = {
      hasBattery = false;
      hasTouchpad = false;
      hasBacklight = false;
      hasBluetooth = true;
      hasNumpad = true;
      enableDev = true;
      enableGaming = true;
      enableAudio = true;
    };

    # ═══════════════════════════════════════════════════════════════════════════
    # Minimal Profile (basic setup)
    # ═══════════════════════════════════════════════════════════════════════════
    minimal = {
      hasBattery = false;
      hasTouchpad = false;
      hasBacklight = false;
      hasBluetooth = false;
      hasNumpad = false;
      enableDev = false;
      enableGaming = false;
      enableAudio = false;
    };
  };

  # Auto-detection helper
  # Returns the appropriate profile based on system hardware
  detectProfile = {
    # Check for battery (laptop indicator)
    hasBattery = lib.pathExists "/sys/class/power_supply/BAT0";
    
    # Check for touchpad
    hasTouchpad = lib.pathExists "/sys/class/input/mouse0";
    
    # Check for backlight control
    hasBacklight = lib.pathExists "/sys/class/backlight";
    
    # Check for bluetooth (requires rfkill)
    # hasBluetooth = ... (would need additional checks)
    
    # Desktop typically has no battery
    # hasNumpad = ... (depends on keyboard)
  };

  # Auto-detected active profile based on hardware
  # This can be used in other modules via lib.attrByPath etc.
  activeProfile = 
    if lib.pathExists "/sys/class/power_supply/BAT0" 
    then "laptop"
    else if lib.pathExists "/sys/class/input/mouse0"
    then "desktop"  # Has mouse input, likely desktop/workstation
    else "minimal";
}

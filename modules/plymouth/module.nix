{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.boot.plymouth.oligarchy;
in
{
  options.boot.plymouth.oligarchy = {
    enable = mkEnableOption "Oligarchy Plymouth theme with DeMoD palette";

    wallpaper = mkOption {
      type = types.nullOr types.path;
      default = null;
      example = literalExpression "./wallpaper.jpg";
      description = ''
        Path to a wallpaper image (JPEG format recommended).
        The image will be scaled to cover the screen while maintaining aspect ratio.
        A dark overlay is automatically applied for text readability.
        
        If null, the theme will use a solid DeMoD color background.
      '';
    };

    overlayOpacity = mkOption {
      type = types.float;
      default = 0.5;
      example = 0.7;
      description = ''
        Opacity of the dark overlay applied to the wallpaper (0.0-1.0).
        Higher values make the background darker and improve text readability.
        Only applies when a wallpaper is set.
      '';
    };

    quiet = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Enable quiet boot (hide kernel messages).
        Recommended for a clean boot experience.
      '';
    };

    consoleLogLevel = mkOption {
      type = types.int;
      default = 3;
      example = 0;
      description = ''
        Console log level (0-7).
        Lower values show fewer messages during boot.
        3 is a good balance between silence and debugging.
      '';
    };
  };

  config = mkIf cfg.enable {
    # Enable Plymouth
    boot.plymouth = {
      enable = true;
      theme = "oligarchy";
    };

    # Apply quiet boot settings if enabled
    boot.kernelParams = mkIf cfg.quiet [ "quiet" ];
    boot.consoleLogLevel = cfg.consoleLogLevel;

    # Copy wallpaper to theme directory if provided
    system.activationScripts.oligarchyPlymouthWallpaper = mkIf (cfg.wallpaper != null) ''
      THEME_DIR="/run/current-system/sw/share/plymouth/themes/oligarchy"
      if [ -d "$THEME_DIR" ]; then
        ${pkgs.coreutils}/bin/cp -f ${cfg.wallpaper} "$THEME_DIR/wallpaper.jpg"
        ${pkgs.coreutils}/bin/chmod 644 "$THEME_DIR/wallpaper.jpg"
      fi
    '';

    # Optional: Update overlay opacity if wallpaper is set
    # This would require dynamic script generation, which is complex
    # For now, users can customize by overriding the package
    warnings = mkIf (cfg.overlayOpacity != 0.5 && cfg.wallpaper != null) [
      ''
        boot.plymouth.oligarchy.overlayOpacity is set to ${toString cfg.overlayOpacity}.
        To apply this, you need to override the theme package and modify line 106 in oligarchy.script.
        See WALLPAPER.md for instructions.
      ''
    ];
  };
}

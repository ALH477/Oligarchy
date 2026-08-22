{ pkgs, lib, themes ? { }, ... }:

# Generates a simple two-stop gradient wallpaper (background -> accent) per
# theme with ImageMagick (already a dependency, home/packages.nix), so
# Super+F8 / theme-switch.sh changes the wallpaper along with everything
# else it already re-skins. No curated per-theme art exists in this repo, so
# a procedural gradient is the closest equivalent to Omarchy's per-theme
# wallpaper sets. theme-switch.sh falls back to the static
# home/hyprland/default.nix wallpaper if a theme's generated file is ever
# missing, so nothing regresses if generation fails.
let
  mkWallpaper = id: pal: pkgs.runCommand "oligarchy-wallpaper-${id}.png" {
    nativeBuildInputs = [ pkgs.imagemagick ];
  } ''
    magick -size 2560x1600 "gradient:${pal.bg}-${pal.accent}" "$out"
  '';
in {
  home.file = lib.mapAttrs'
    (id: pal: lib.nameValuePair ".config/oligarchy/themes/${id}/wallpaper.png" {
      source = mkWallpaper id pal;
    })
    themes;
}

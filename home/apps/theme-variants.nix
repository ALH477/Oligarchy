{ config, pkgs, lib, themes ? { }, ... }:

# Renders every palette in home/themes/default.nix to disk as plain JSON,
# under ~/.config/oligarchy/themes/<id>/palette.json, plus a manifest listing
# every theme id + display name. This is the single source of truth
# theme-switch.sh reads from — it used to carry its own hand-copied,
# already-drifted subset of each palette's colors (missing fields, and
# several hex values that no longer matched home/themes/default.nix). Now
# there is exactly one place palette data is written down.
#
# Each themed app module (wofi/hyprlock/gtk-theming/kvantum/waybar/kitty)
# separately renders its OWN per-theme variant file next to these (e.g.
# .../themes/<id>/wofi.css) — this module only owns the palette data itself,
# not any app's rendering of it.
{
  home.file = {
    ".config/oligarchy/themes/manifest.json".text = builtins.toJSON
      (lib.mapAttrsToList (id: pal: { inherit id; name = pal.name; }) themes);
  } // (lib.mapAttrs'
    (id: pal:
      lib.nameValuePair ".config/oligarchy/themes/${id}/palette.json" {
        text = builtins.toJSON pal;
      })
    themes);
}

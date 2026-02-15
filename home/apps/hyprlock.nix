{ config, pkgs, lib, theme ? {}, ... }:

let
  p = theme;
in {
  # ══════════════════════════════════════════════════════════════════════════
  # Hyprlock Screen Lock Configuration
  # ══════════════════════════════════════════════════════════════════════════
  home.file.".config/hypr/hyprlock.conf".text = ''
    general {
      disable_loading_bar = false
      hide_cursor = true
      grace = 3
    }

    background {
      monitor =
      path = screenshot
      blur_passes = 4
      blur_size = 10
      brightness = 0.6
      vibrancy = 0.2
    }

    label {
      monitor =
      text = $TIME
      font_size = 96
      font_family = JetBrains Mono Bold
      color = rgba(${lib.removePrefix "#" p.accent}ff)
      position = 0, 180
      halign = center
      valign = center
      shadow_passes = 2
      shadow_size = 4
      shadow_color = rgba(0, 0, 0, 0.5)
    }

    label {
      monitor =
      text = cmd[update:3600000] date +"%A, %B %d"
      font_size = 20
      font_family = JetBrains Mono
      color = rgba(${lib.removePrefix "#" p.textAlt}dd)
      position = 0, 80
      halign = center
      valign = center
    }

    label {
      monitor =
      text = 󰀄  $USER
      font_size = 16
      font_family = JetBrainsMono Nerd Font
      color = rgba(${lib.removePrefix "#" p.text}cc)
      position = 0, -60
      halign = center
      valign = center
    }

    input-field {
      monitor =
      size = 320, 55
      outline_thickness = 3
      dots_size = 0.25
      dots_spacing = 0.2
      dots_center = true
      outer_color = rgba(${lib.removePrefix "#" p.accent}ee)
      inner_color = rgba(${lib.removePrefix "#" p.surface}ee)
      font_color = rgba(${lib.removePrefix "#" p.text}ff)
      fade_on_empty = false
      placeholder_text = <i>󰌾  Enter Password...</i>
      hide_input = false
      position = 0, -140
      halign = center
      valign = center
      rounding = 14
      shadow_passes = 2
      shadow_size = 4
    }

    label {
      monitor =
      text = 󱄅  DeMoD Workstation
      font_size = 12
      font_family = JetBrainsMono Nerd Font
      color = rgba(${lib.removePrefix "#" p.textDim}88)
      position = 0, -240
      halign = center
      valign = center
    }
  '';
}

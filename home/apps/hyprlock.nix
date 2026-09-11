{ config, pkgs, lib, theme ? {}, themes ? {}, ... }:

let
  p = theme;

  # See home/apps/wofi.nix for why this is factored into a function of `p`.
  renderConf = p: ''
    general {
      hide_cursor = true
      # Draw immediately instead of waiting on background resources. Without
      # this the lock surface is not finished (and so never becomes the
      # keyboard focus) until its background resolves -- which is exactly what
      # fails across a dpms-off/resume cycle. `disable_loading_bar` and `grace`
      # used to live here and were REMOVED in hyprlock 0.9.x: they parsed as
      # "config option does not exist" errors on every single lock, and `grace`
      # silently did nothing. Grace is a CLI flag now, passed in the
      # hyprlock.service ExecStart (see home/hyprland/default.nix).
      immediate_render = true
    }

    background {
      monitor =
      # NOT `screenshot`. That routes the background through screencopy ->
      # dmabuf import, which (a) cannot complete against an output that dpms
      # tore down, leaving a lock surface that never takes the keyboard, and
      # (b) is the amdgpu/TTM path hyprlock wedged in uninterruptibly -- a
      # process SIGKILL cannot touch, which cost one shutdown 3m44s. Blur over
      # a static image is a one-shot GL cost and needs neither.
      path = ~/.config/hypr/wallpapers/default.jpg
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
      text = 󱄅  Oligarchy
      font_size = 12
      font_family = JetBrainsMono Nerd Font
      color = rgba(${lib.removePrefix "#" p.textDim}88)
      position = 0, -240
      halign = center
      valign = center
    }
  '';
in {
  # ══════════════════════════════════════════════════════════════════════════
  # Hyprlock Screen Lock Configuration
  # ══════════════════════════════════════════════════════════════════════════
  home.file = {
    ".config/hypr/hyprlock.conf".text = renderConf p;
  } // (lib.mapAttrs'
    (id: pal: lib.nameValuePair ".config/oligarchy/themes/${id}/hyprlock.conf" {
      text = renderConf pal;
    })
    themes);
}

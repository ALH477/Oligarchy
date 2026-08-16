{ config, pkgs, lib, theme ? {}, themes ? {}, ... }:

let
  p = theme;  # Shorthand for palette

  # Just the color assignments, in plain kitty-conf syntax ("key value", not
  # "key = value") — this is what `kitty @ set-colors --all --config <file>`
  # (theme-switch.sh) applies live to every running kitty window without a
  # rebuild. Requires allow_remote_control below.
  renderColors = p: ''
    background ${p.bg}
    foreground ${p.text}
    selection_background ${p.accent}
    selection_foreground ${p.bg}
    cursor ${p.accent}
    cursor_text_color ${p.bg}
    color0 ${p.black}
    color8 ${p.brightBlack}
    color1 ${p.red}
    color9 ${p.brightRed}
    color2 ${p.green}
    color10 ${p.brightGreen}
    color3 ${p.yellow}
    color11 ${p.brightYellow}
    color4 ${p.blue}
    color12 ${p.brightBlue}
    color5 ${p.magenta}
    color13 ${p.brightMagenta}
    color6 ${p.cyan}
    color14 ${p.brightCyan}
    color7 ${p.white}
    color15 ${p.brightWhite}
    active_tab_background ${p.accent}
    active_tab_foreground ${p.bg}
    inactive_tab_background ${p.surface}
    inactive_tab_foreground ${p.textAlt}
  '';
in {
  programs.kitty = {
    enable = true;
    settings = {
      # Font settings
      font_family = "JetBrainsMono Nerd Font";
      bold_font = "JetBrainsMono Nerd Font Bold";
      font_size = 11;

      # Cursor
      cursor_shape = "beam";
      cursor_blink_interval = 0;

      # Window
      scrollback_lines = 10000;
      window_padding_width = 12;
      hide_window_decorations = "yes";
      confirm_os_window_close = 0;
      enable_audio_bell = false;
      url_style = "curly";

      # Remote control, loopback-only via a user-owned Unix socket — needed
      # for theme-switch.sh's live `kitty @ set-colors` (no network exposure,
      # matches this repo's loopback-only convention for local control
      # sockets elsewhere, e.g. ports-sec's MCP crate). {kitty_pid} keeps each
      # socket path unique: home/hyprland/default.nix's exec-once pre-spawns
      # three independent scratchpad kitty *processes*, and a shared static
      # path would make the 2nd/3rd instance fail to bind (already in use).
      # theme-switch.sh globs /tmp/kitty-<user>-*.sock to reach all of them.
      allow_remote_control = "socket-only";
      listen_on = "unix:/tmp/kitty-${config.home.username}-{kitty_pid}.sock";

      # Theme colors
      background = p.bg;
      foreground = p.text;
      selection_background = p.accent;
      selection_foreground = p.bg;
      cursor = p.accent;
      cursor_text_color = p.bg;

      # Terminal colors (ANSI)
      color0 = p.black;
      color8 = p.brightBlack;
      color1 = p.red;
      color9 = p.brightRed;
      color2 = p.green;
      color10 = p.brightGreen;
      color3 = p.yellow;
      color11 = p.brightYellow;
      color4 = p.blue;
      color12 = p.brightBlue;
      color5 = p.magenta;
      color13 = p.brightMagenta;
      color6 = p.cyan;
      color14 = p.brightCyan;
      color7 = p.white;
      color15 = p.brightWhite;

      # Tab bar
      tab_bar_style = "powerline";
      tab_powerline_style = "slanted";
      active_tab_background = p.accent;
      active_tab_foreground = p.bg;
      inactive_tab_background = p.surface;
      inactive_tab_foreground = p.textAlt;
    };
  };

  home.file = lib.mapAttrs'
    (id: pal: lib.nameValuePair ".config/oligarchy/themes/${id}/kitty.conf" {
      text = renderColors pal;
    })
    themes;
}

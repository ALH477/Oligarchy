{ config, pkgs, lib, theme ? {}, ... }:

let
  p = theme;  # Shorthand for palette
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
}

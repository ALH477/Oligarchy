{ lib }:

{
  palettes = {
    # ══════════════════════════════════════════════════════════════════════════
    # DeMoD - Radical Retro-Tech Palette
    # ══════════════════════════════════════════════════════════════════════════
    demod = {
      name = "DeMoD";
      bg = "#080810";
      bgAlt = "#0C0C14";
      surface = "#101018";
      surfaceAlt = "#161620";
      overlay = "#1C1C28";
      border = "#252530";
      borderFocus = "#00F5D4";
      borderHover = "#8B5CF6";
      accent = "#00F5D4";
      accentAlt = "#00E5C7";
      accentDim = "#00B89F";
      gradientStart = "#00F5D4";
      gradientEnd = "#8B5CF6";
      gradientAngle = "135deg";
      text = "#FFFFFF";
      textAlt = "#E0E0E0";
      textDim = "#808080";
      textOnAccent = "#080810";
      success = "#39FF14";
      warning = "#FFE814";
      error = "#FF3B5C";
      info = "#00F5D4";
      purple = "#8B5CF6";
      pink = "#A78BFA";
      orange = "#FF9500";
      violet = "#8B5CF6";
      glowTurquoise = "0 0 20px rgba(0, 245, 212, 0.3)";
      glowViolet = "0 0 20px rgba(139, 92, 246, 0.3)";
      black = "#080810";
      brightBlack = "#404050";
      red = "#FF3B5C";
      brightRed = "#FF6B7F";
      green = "#39FF14";
      brightGreen = "#69FF4D";
      yellow = "#FFE814";
      brightYellow = "#FFEF5C";
      blue = "#00B4D8";
      brightBlue = "#00F5D4";
      magenta = "#8B5CF6";
      brightMagenta = "#A78BFA";
      cyan = "#00F5D4";
      brightCyan = "#5CFFE8";
      white = "#E0E0E0";
      brightWhite = "#FFFFFF";
    };

    # ══════════════════════════════════════════════════════════════════════════
    # Catppuccin Mocha
    # ══════════════════════════════════════════════════════════════════════════
    catppuccin = {
      name = "Catppuccin";
      bg = "#11111B";
      bgAlt = "#181825";
      surface = "#1E1E2E";
      surfaceAlt = "#313244";
      overlay = "#45475A";
      border = "#45475A";
      borderFocus = "#CBA6F7";
      borderHover = "#F5C2E7";
      accent = "#CBA6F7";
      accentAlt = "#F5C2E7";
      accentDim = "#B4A0E5";
      gradientStart = "#CBA6F7";
      gradientEnd = "#F5C2E7";
      gradientAngle = "45deg";
      text = "#CDD6F4";
      textAlt = "#BAC2DE";
      textDim = "#6C7086";
      textOnAccent = "#11111B";
      success = "#A6E3A1";
      warning = "#F9E2AF";
      error = "#F38BA8";
      info = "#89DCEB";
      purple = "#CBA6F7";
      pink = "#F5C2E7";
      orange = "#FAB387";
      yellow = "#F9E2AF";
      cyan = "#89DCEB";
      green = "#A6E3A1";
      black = "#11111B";
      brightBlack = "#45475A";
      red = "#F38BA8";
      brightRed = "#F5A0B8";
      brightGreen = "#B8EBB3";
      brightYellow = "#FBE9C0";
      blue = "#89B4FA";
      brightBlue = "#A0C4FC";
      magenta = "#CBA6F7";
      brightMagenta = "#DDB8F9";
      brightCyan = "#A0E8F5";
      white = "#CDD6F4";
      brightWhite = "#FFFFFF";
    };

    # ══════════════════════════════════════════════════════════════════════════
    # Nord
    # ══════════════════════════════════════════════════════════════════════════
    nord = {
      name = "Nord";
      bg = "#242933";
      bgAlt = "#2E3440";
      surface = "#3B4252";
      surfaceAlt = "#434C5E";
      overlay = "#4C566A";
      border = "#4C566A";
      borderFocus = "#88C0D0";
      borderHover = "#81A1C1";
      accent = "#88C0D0";
      accentAlt = "#81A1C1";
      accentDim = "#5E81AC";
      gradientStart = "#88C0D0";
      gradientEnd = "#81A1C1";
      gradientAngle = "45deg";
      text = "#ECEFF4";
      textAlt = "#E5E9F0";
      textDim = "#D8DEE9";
      textOnAccent = "#2E3440";
      success = "#A3BE8C";
      warning = "#EBCB8B";
      error = "#BF616A";
      info = "#81A1C1";
      purple = "#B48EAD";
      pink = "#B48EAD";
      orange = "#D08770";
      yellow = "#EBCB8B";
      cyan = "#88C0D0";
      green = "#A3BE8C";
      black = "#2E3440";
      brightBlack = "#4C566A";
      red = "#BF616A";
      brightRed = "#D08770";
      brightGreen = "#B5CEA0";
      brightYellow = "#F0D9A0";
      blue = "#81A1C1";
      brightBlue = "#88C0D0";
      magenta = "#B48EAD";
      brightMagenta = "#C6A0BF";
      brightCyan = "#8FBCBB";
      white = "#E5E9F0";
      brightWhite = "#ECEFF4";
    };

    # ══════════════════════════════════════════════════════════════════════════
    # Rosé Pine
    # ══════════════════════════════════════════════════════════════════════════
    rosepine = {
      name = "Rosé Pine";
      bg = "#191724";
      bgAlt = "#1F1D2E";
      surface = "#26233A";
      surfaceAlt = "#2A273F";
      overlay = "#393552";
      border = "#403D52";
      borderFocus = "#C4A7E7";
      borderHover = "#EBBCBA";
      accent = "#C4A7E7";
      accentAlt = "#EBBCBA";
      accentDim = "#9C8EC4";
      gradientStart = "#C4A7E7";
      gradientEnd = "#EBBCBA";
      gradientAngle = "45deg";
      text = "#E0DEF4";
      textAlt = "#908CAA";
      textDim = "#6E6A86";
      textOnAccent = "#191724";
      success = "#9CCFD8";
      warning = "#F6C177";
      error = "#EB6F92";
      info = "#31748F";
      purple = "#C4A7E7";
      pink = "#EBBCBA";
      orange = "#F6C177";
      yellow = "#F6C177";
      cyan = "#9CCFD8";
      green = "#9CCFD8";
      black = "#191724";
      brightBlack = "#403D52";
      red = "#EB6F92";
      brightRed = "#F0A0B0";
      brightGreen = "#B0DFE5";
      brightYellow = "#F9D5A0";
      blue = "#31748F";
      brightBlue = "#5A99AD";
      magenta = "#C4A7E7";
      brightMagenta = "#D4BFEF";
      brightCyan = "#B0DFE5";
      white = "#E0DEF4";
      brightWhite = "#FFFFFF";
    };

    # ══════════════════════════════════════════════════════════════════════════
    # Gruvbox Material Dark
    # ══════════════════════════════════════════════════════════════════════════
    gruvbox = {
      name = "Gruvbox";
      bg = "#1d2021";
      bgAlt = "#282828";
      surface = "#3c3836";
      surfaceAlt = "#504945";
      overlay = "#665c54";
      border = "#665c54";
      borderFocus = "#d79921";
      borderHover = "#98971a";
      accent = "#d79921";
      accentAlt = "#98971a";
      accentDim = "#b16286";
      gradientStart = "#d79921";
      gradientEnd = "#FABD2F";
      gradientAngle = "45deg";
      text = "#ebdbb2";
      textAlt = "#d5c4a1";
      textDim = "#a89984";
      textOnAccent = "#1d2021";
      success = "#b8bb26";
      warning = "#fabd2f";
      error = "#fb4934";
      info = "#83a598";
      purple = "#b16286";
      pink = "#d3869b";
      orange = "#fe8019";
      yellow = "#fabd2f";
      cyan = "#8ec07c";
      green = "#b8bb26";
      black = "#1d2021";
      brightBlack = "#665c54";
      red = "#cc241d";
      brightRed = "#fb4934";
      brightGreen = "#b8bb26";
      brightYellow = "#fabd2f";
      blue = "#458588";
      brightBlue = "#83a598";
      magenta = "#b16286";
      brightMagenta = "#d3869b";
      brightCyan = "#8ec07c";
      white = "#ebdbb2";
      brightWhite = "#fbf1c7";
    };

    # ══════════════════════════════════════════════════════════════════════════
    # Dracula
    # ══════════════════════════════════════════════════════════════════════════
    dracula = {
      name = "Dracula";
      bg = "#1E1F29";
      bgAlt = "#282A36";
      surface = "#343746";
      surfaceAlt = "#44475A";
      overlay = "#4D4F68";
      border = "#44475A";
      borderFocus = "#BD93F9";
      borderHover = "#FF79C6";
      accent = "#BD93F9";
      accentAlt = "#FF79C6";
      accentDim = "#9B7AD6";
      gradientStart = "#BD93F9";
      gradientEnd = "#FF79C6";
      gradientAngle = "45deg";
      text = "#F8F8F2";
      textAlt = "#BFBFBF";
      textDim = "#6272A4";
      textOnAccent = "#282A36";
      success = "#50FA7B";
      warning = "#F1FA8C";
      error = "#FF5555";
      info = "#8BE9FD";
      purple = "#BD93F9";
      pink = "#FF79C6";
      orange = "#FFB86C";
      yellow = "#F1FA8C";
      cyan = "#8BE9FD";
      green = "#50FA7B";
      black = "#282A36";
      brightBlack = "#44475A";
      red = "#FF5555";
      brightRed = "#FF6E6E";
      brightGreen = "#69FF94";
      brightYellow = "#F4FCA0";
      blue = "#8BE9FD";
      brightBlue = "#A4EFFF";
      magenta = "#FF79C6";
      brightMagenta = "#FF92D0";
      brightCyan = "#A4EFFF";
      white = "#F8F8F2";
      brightWhite = "#FFFFFF";
    };

    # ══════════════════════════════════════════════════════════════════════════
    # Tokyo Night
    # ══════════════════════════════════════════════════════════════════════════
    tokyo = {
      name = "Tokyo Night";
      bg = "#16161E";
      bgAlt = "#1A1B26";
      surface = "#24283B";
      surfaceAlt = "#292E42";
      overlay = "#343A52";
      border = "#3B4261";
      borderFocus = "#7AA2F7";
      borderHover = "#BB9AF7";
      accent = "#7AA2F7";
      accentAlt = "#BB9AF7";
      accentDim = "#5A7DD6";
      gradientStart = "#7AA2F7";
      gradientEnd = "#BB9AF7";
      gradientAngle = "45deg";
      text = "#C0CAF5";
      textAlt = "#A9B1D6";
      textDim = "#565F89";
      textOnAccent = "#1A1B26";
      success = "#9ECE6A";
      warning = "#E0AF68";
      error = "#F7768E";
      info = "#7DCFFF";
      purple = "#BB9AF7";
      pink = "#FF007C";
      orange = "#FF9E64";
      yellow = "#E0AF68";
      cyan = "#7DCFFF";
      green = "#9ECE6A";
      black = "#1A1B26";
      brightBlack = "#414868";
      red = "#F7768E";
      brightRed = "#FF899D";
      brightGreen = "#B2DC82";
      brightYellow = "#ECC580";
      blue = "#7AA2F7";
      brightBlue = "#8CB4F9";
      magenta = "#BB9AF7";
      brightMagenta = "#CDACF9";
      brightCyan = "#91D9FF";
      white = "#C0CAF5";
      brightWhite = "#FFFFFF";
    };

    # ══════════════════════════════════════════════════════════════════════════
    # Phosphor (Neon Cyberpunk)
    # ══════════════════════════════════════════════════════════════════════════
    phosphor = {
      name = "Phosphor";
      bg = "#0a0a0a";
      bgAlt = "#141414";
      surface = "#1a1a1a";
      surfaceAlt = "#262626";
      overlay = "#404040";
      border = "#404040";
      borderFocus = "#00ffff";
      borderHover = "#ff00ff";
      accent = "#00ffff";
      accentAlt = "#ff00ff";
      accentDim = "#00ff00";
      gradientStart = "#00ffff";
      gradientEnd = "#ff00ff";
      gradientAngle = "90deg";
      text = "#ffffff";
      textAlt = "#e0e0e0";
      textDim = "#808080";
      textOnAccent = "#0a0a0a";
      success = "#00ff00";
      warning = "#ffff00";
      error = "#ff0040";
      info = "#00ffff";
      purple = "#ff00ff";
      pink = "#ff0080";
      orange = "#ff8000";
      yellow = "#ffff00";
      cyan = "#00ffff";
      green = "#00ff00";
      black = "#000000";
      brightBlack = "#404040";
      red = "#ff0040";
      brightRed = "#ff4080";
      brightGreen = "#40ff40";
      brightYellow = "#ffff40";
      blue = "#0080ff";
      brightBlue = "#40c0ff";
      magenta = "#ff00ff";
      brightMagenta = "#ff40ff";
      brightCyan = "#00ffff";
      white = "#ffffff";
      brightWhite = "#ffffff";
    };
  };

  # Theme preview function for quick testing
  previewPalette = palette: ''
    ${lib.pipe palette [
      (lib.filterAttrs (name: value: builtins.match ".*(color|bg|text).*" name != null))
      (lib.mapAttrsToList (name: color: "${name}: ${color}"))
      (lib.concatStringsSep "\n")
    ]}
  '';

  # Active theme - set default here
  # Options: demod, catppuccin, nord, rosepine, gruvbox, dracula, tokyo, phosphor
  activeThemeName = "demod";

  # Get the active palette
  activePalette = palettes.${activeThemeName};
}

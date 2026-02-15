{ lib, ... }:

{
  # ════════════════════════════════════════════════════════════════════════════
  # KDE Color Utilities - Hex to RGB conversion and palette generation
  # ════════════════════════════════════════════════════════════════════════════
  
  # Convert hex color (#RRGGBB) to KDE RGB format (R,G,B)
  hexToKdeRgb = hex:
    let
      hex' = lib.removePrefix "#" hex;
      r = lib.substring 0 2 hex';
      g = lib.substring 2 2 hex';
      b = lib.substring 4 2 hex';
      toDec = s: lib.toIntBase16 s;
    in "${toString (toDec r)},${toString (toDec g)},${toString (toDec b)}";

  # Generate all KDE color mappings from a palette
  mkKdeColors = palette: {
    bg = lib.removePrefix "#" palette.bg;
    bgAlt = lib.removePrefix "#" palette.bgAlt;
    surface = lib.removePrefix "#" palette.surface;
    surfaceAlt = lib.removePrefix "#" palette.surfaceAlt;
    overlay = lib.removePrefix "#" palette.overlay;
    border = lib.removePrefix "#" palette.border;
    borderFocus = lib.removePrefix "#" palette.borderFocus;
    borderHover = lib.removePrefix "#" palette.borderHover;
    accent = lib.removePrefix "#" palette.accent;
    accentAlt = lib.removePrefix "#" palette.accentAlt;
    text = lib.removePrefix "#" palette.text;
    textAlt = lib.removePrefix "#" palette.textAlt;
    textDim = lib.removePrefix "#" palette.textDim;
    textOnAccent = lib.removePrefix "#" palette.textOnAccent;
    success = lib.removePrefix "#" palette.success;
    warning = lib.removePrefix "#" palette.warning;
    error = lib.removePrefix "#" palette.error;
    info = lib.removePrefix "#" palette.info;
    purple = lib.removePrefix "#" palette.purple;
    pink = lib.removePrefix "#" palette.pink;
    orange = lib.removePrefix "#" palette.orange;
    yellow = lib.removePrefix "#" palette.yellow;
    cyan = lib.removePrefix "#" palette.cyan;
    green = lib.removePrefix "#" palette.green;
    black = lib.removePrefix "#" palette.black;
    brightBlack = lib.removePrefix "#" palette.brightBlack;
    red = lib.removePrefix "#" palette.red;
    brightRed = lib.removePrefix "#" palette.brightRed;
    brightGreen = lib.removePrefix "#" palette.brightGreen;
    brightYellow = lib.removePrefix "#" palette.brightYellow;
    blue = lib.removePrefix "#" palette.blue;
    brightBlue = lib.removePrefix "#" palette.brightBlue;
    magenta = lib.removePrefix "#" palette.magenta;
    brightMagenta = lib.removePrefix "#" palette.brightMagenta;
    white = lib.removePrefix "#" palette.white;
    brightWhite = lib.removePrefix "#" palette.brightWhite;
  };

  # All available palettes for generating color schemes
  allPalettes = {
    demod = {
      name = "DeMoD";
      bg = "#080810"; bgAlt = "#0C0C14"; surface = "#101018"; surfaceAlt = "#161620"; overlay = "#1C1C28";
      border = "#252530"; borderFocus = "#00F5D4"; borderHover = "#8B5CF6";
      accent = "#00F5D4"; accentAlt = "#00E5C7"; accentDim = "#00B89F";
      gradientStart = "#00F5D4"; gradientEnd = "#8B5CF6"; gradientAngle = "135deg";
      text = "#FFFFFF"; textAlt = "#E0E0E0"; textDim = "#808080"; textOnAccent = "#080810";
      success = "#39FF14"; warning = "#FFE814"; error = "#FF3B5C"; info = "#00F5D4";
      purple = "#8B5CF6"; pink = "#A78BFA"; orange = "#FF9500"; yellow = "#FFE814";
      cyan = "#00F5D4"; green = "#39FF14";
      black = "#080810"; brightBlack = "#404050";
      red = "#FF3B5C"; brightRed = "#FF6B7F";
      green = "#39FF14"; brightGreen = "#69FF4D";
      yellow = "#FFE814"; brightYellow = "#FFEF5C";
      blue = "#00B4D8"; brightBlue = "#00F5D4";
      magenta = "#8B5CF6"; brightMagenta = "#A78BFA";
      white = "#E0E0E0"; brightWhite = "#FFFFFF";
    };

    catppuccin = {
      name = "Catppuccin";
      bg = "#11111B"; bgAlt = "#181825"; surface = "#1E1E2E"; surfaceAlt = "#313244"; overlay = "#45475A";
      border = "#45475A"; borderFocus = "#CBA6F7"; borderHover = "#F5C2E7";
      accent = "#CBA6F7"; accentAlt = "#F5C2E7"; accentDim = "#B4A0E5";
      gradientStart = "#CBA6F7"; gradientEnd = "#F5C2E7"; gradientAngle = "45deg";
      text = "#CDD6F4"; textAlt = "#BAC2DE"; textDim = "#6C7086"; textOnAccent = "#11111B";
      success = "#A6E3A1"; warning = "#F9E2AF"; error = "#F38BA8"; info = "#89DCEB";
      purple = "#CBA6F7"; pink = "#F5C2E7"; orange = "#FAB387"; yellow = "#F9E2AF";
      cyan = "#89DCEB"; green = "#A6E3A1";
      black = "#11111B"; brightBlack = "#45475A";
      red = "#F38BA8"; brightRed = "#F5A0B8";
      green = "#A6E3A1"; brightGreen = "#B8EBB3";
      yellow = "#F9E2AF"; brightYellow = "#FBE9C0";
      blue = "#89B4FA"; brightBlue = "#A0C4FC";
      magenta = "#CBA6F7"; brightMagenta = "#DDB8F9";
      white = "#CDD6F4"; brightWhite = "#FFFFFF";
    };

    nord = {
      name = "Nord";
      bg = "#242933"; bgAlt = "#2E3440"; surface = "#3B4252"; surfaceAlt = "#434C5E"; overlay = "#4C566A";
      border = "#4C566A"; borderFocus = "#88C0D0"; borderHover = "#81A1C1";
      accent = "#88C0D0"; accentAlt = "#81A1C1"; accentDim = "#5E81AC";
      gradientStart = "#88C0D0"; gradientEnd = "#81A1C1"; gradientAngle = "45deg";
      text = "#ECEFF4"; textAlt = "#E5E9F0"; textDim = "#D8DEE9"; textOnAccent = "#2E3440";
      success = "#A3BE8C"; warning = "#EBCB8B"; error = "#BF616A"; info = "#81A1C1";
      purple = "#B48EAD"; pink = "#B48EAD"; orange = "#D08770"; yellow = "#EBCB8B";
      cyan = "#88C0D0"; green = "#A3BE8C";
      black = "#2E3440"; brightBlack = "#4C566A";
      red = "#BF616A"; brightRed = "#D08770";
      green = "#A3BE8C"; brightGreen = "#B5CEA0";
      yellow = "#EBCB8B"; brightYellow = "#F0D9A0";
      blue = "#81A1C1"; brightBlue = "#88C0D0";
      magenta = "#B48EAD"; brightMagenta = "#C6A0BF";
      white = "#E5E9F0"; brightWhite = "#ECEFF4";
    };

    rosepine = {
      name = "Rosé Pine";
      bg = "#191724"; bgAlt = "#1F1D2E"; surface = "#26233A"; surfaceAlt = "#2A273F"; overlay = "#393552";
      border = "#403D52"; borderFocus = "#C4A7E7"; borderHover = "#EBBCBA";
      accent = "#C4A7E7"; accentAlt = "#EBBCBA"; accentDim = "#9C8EC4";
      gradientStart = "#C4A7E7"; gradientEnd = "#EBBCBA"; gradientAngle = "45deg";
      text = "#E0DEF4"; textAlt = "#908CAA"; textDim = "#6E6A86"; textOnAccent = "#191724";
      success = "#9CCFD8"; warning = "#F6C177"; error = "#EB6F92"; info = "#31748F";
      purple = "#C4A7E7"; pink = "#EBBCBA"; orange = "#F6C177"; yellow = "#F6C177";
      cyan = "#9CCFD8"; green = "#9CCFD8";
      black = "#191724"; brightBlack = "#403D52";
      red = "#EB6F92"; brightRed = "#F0A0B0";
      green = "#9CCFD8"; brightGreen = "#B0DFE5";
      yellow = "#F6C177"; brightYellow = "#F9D5A0";
      blue = "#31748F"; brightBlue = "#5A99AD";
      magenta = "#C4A7E7"; brightMagenta = "#D4BFEF";
      white = "#E0DEF4"; brightWhite = "#FFFFFF";
    };

    gruvbox = {
      name = "Gruvbox";
      bg = "#1D2021"; bgAlt = "#282828"; surface = "#32302F"; surfaceAlt = "#3C3836"; overlay = "#504945";
      border = "#504945"; borderFocus = "#D79921"; borderHover = "#FABD2F";
      accent = "#D79921"; accentAlt = "#FABD2F"; accentDim = "#B57614";
      gradientStart = "#D79921"; gradientEnd = "#FABD2F"; gradientAngle = "45deg";
      text = "#EBDBB2"; textAlt = "#D5C4A1"; textDim = "#928374"; textOnAccent = "#282828";
      success = "#B8BB26"; warning = "#FABD2F"; error = "#FB4934"; info = "#83A598";
      purple = "#D3869B"; pink = "#D3869B"; orange = "#FE8019"; yellow = "#FABD2F";
      cyan = "#8EC07C"; green = "#B8BB26";
      black = "#282828"; brightBlack = "#504945";
      red = "#FB4934"; brightRed = "#FE8019";
      green = "#B8BB26"; brightGreen = "#98971A";
      yellow = "#FABD2F"; brightYellow = "#FCE566";
      blue = "#83A598"; brightBlue = "#458588";
      magenta = "#D3869B"; brightMagenta = "#B16286";
      white = "#EBDBB2"; brightWhite = "#FBF1C7";
    };

    dracula = {
      name = "Dracula";
      bg = "#1E1F29"; bgAlt = "#282A36"; surface = "#343746"; surfaceAlt = "#44475A"; overlay = "#4D4F68";
      border = "#44475A"; borderFocus = "#BD93F9"; borderHover = "#FF79C6";
      accent = "#BD93F9"; accentAlt = "#FF79C6"; accentDim = "#9B7AD6";
      gradientStart = "#BD93F9"; gradientEnd = "#FF79C6"; gradientAngle = "45deg";
      text = "#F8F8F2"; textAlt = "#BFBFBF"; textDim = "#6272A4"; textOnAccent = "#282A36";
      success = "#50FA7B"; warning = "#F1FA8C"; error = "#FF5555"; info = "#8BE9FD";
      purple = "#BD93F9"; pink = "#FF79C6"; orange = "#FFB86C"; yellow = "#F1FA8C";
      cyan = "#8BE9FD"; green = "#50FA7B";
      black = "#282A36"; brightBlack = "#44475A";
      red = "#FF5555"; brightRed = "#FF6E6E";
      green = "#50FA7B"; brightGreen = "#69FF94";
      yellow = "#F1FA8C"; brightYellow = "#F4FCA0";
      blue = "#8BE9FD"; brightBlue = "#A4EFFF";
      magenta = "#FF79C6"; brightMagenta = "#FF92D0";
      white = "#F8F8F2"; brightWhite = "#FFFFFF";
    };

    tokyo = {
      name = "Tokyo Night";
      bg = "#16161E"; bgAlt = "#1A1B26"; surface = "#24283B"; surfaceAlt = "#292E42"; overlay = "#343A52";
      border = "#3B4261"; borderFocus = "#7AA2F7"; borderHover = "#BB9AF7";
      accent = "#7AA2F7"; accentAlt = "#BB9AF7"; accentDim = "#5A7DD6";
      gradientStart = "#7AA2F7"; gradientEnd = "#BB9AF7"; gradientAngle = "45deg";
      text = "#C0CAF5"; textAlt = "#A9B1D6"; textDim = "#565F89"; textOnAccent = "#1A1B26";
      success = "#9ECE6A"; warning = "#E0AF68"; error = "#F7768E"; info = "#7DCFFF";
      purple = "#BB9AF7"; pink = "#FF007C"; orange = "#FF9E64"; yellow = "#E0AF68";
      cyan = "#7DCFFF"; green = "#9ECE6A";
      black = "#1A1B26"; brightBlack = "#414868";
      red = "#F7768E"; brightRed = "#FF899D";
      green = "#9ECE6A"; brightGreen = "#B2DC82";
      yellow = "#E0AF68"; brightYellow = "#ECC580";
      blue = "#7AA2F7"; brightBlue = "#8CB4F9";
      magenta = "#BB9AF7"; brightMagenta = "#CDACF9";
      white = "#C0CAF5"; brightWhite = "#FFFFFF";
    };

    phosphor = {
      name = "Phosphor";
      bg = "#0A0A0A"; bgAlt = "#0D0D0D"; surface = "#141414"; surfaceAlt = "#1A1A1A"; overlay = "#222222";
      border = "#2A2A2A"; borderFocus = "#39FF14"; borderHover = "#00FF88";
      accent = "#39FF14"; accentAlt = "#32CD32"; accentDim = "#228B22";
      gradientStart = "#39FF14"; gradientEnd = "#00FF88"; gradientAngle = "180deg";
      text = "#33FF33"; textAlt = "#22CC22"; textDim = "#117711"; textOnAccent = "#0A0A0A";
      success = "#39FF14"; warning = "#FFFF00"; error = "#FF0040"; info = "#39FF14";
      purple = "#9D00FF"; pink = "#FF00FF"; orange = "#FF8800"; yellow = "#FFFF00";
      cyan = "#00FFFF"; green = "#39FF14";
      black = "#0A0A0A"; brightBlack = "#333333";
      red = "#FF0040"; brightRed = "#FF3366";
      green = "#39FF14"; brightGreen = "#69FF4D";
      yellow = "#FFFF00"; brightYellow = "#FFFF66";
      blue = "#00AAFF"; brightBlue = "#00DDFF";
      magenta = "#FF00FF"; brightMagenta = "#FF66FF";
      white = "#33FF33"; brightWhite = "#66FF66";
    };
  };
}

{ ... }:

# ─────────────────────────────────────────────────────────────────────────────
# Oligarchy Control Center
# A unified control surface over the project's scattered toggles/CLIs:
#   oligarchy-menu     — Wofi graphical hub   (bound to Super+D in hyprland)
#   oligarchy-control  — fzf terminal TUI      (also the greeting's launch target)
#   oligarchy-ctl      — shared action dispatcher both front-ends call
# Deployed to ~/.local/bin (on sessionPath) as plain scripts so there is no
# heavy build cost — they reuse the existing CLIs and the runtime theme.json.
# ─────────────────────────────────────────────────────────────────────────────

{
  home.file.".local/bin/oligarchy-ctl" = {
    source = ./control-center/oligarchy-ctl.sh;
    executable = true;
  };
  home.file.".local/bin/oligarchy-menu" = {
    source = ./control-center/oligarchy-menu.sh;
    executable = true;
  };
  home.file.".local/bin/oligarchy-control" = {
    source = ./control-center/oligarchy-control.sh;
    executable = true;
  };
}

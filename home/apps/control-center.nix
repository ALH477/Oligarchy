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
  home.file.".local/bin/dsp-bench" = {
    source = ./control-center/dsp-bench.sh;
    executable = true;
  };
  home.file.".local/bin/oligarchy-warroom" = {
    source = ./control-center/oligarchy-warroom.sh;
    executable = true;
  };
  home.file.".local/bin/oligarchy-dsp" = {
    source = ./control-center/oligarchy-dsp.sh;
    executable = true;
  };
  # Unified command center TUI — delegates to all other oligarchy-* commands.
  home.file.".local/bin/oligarchy" = {
    source = ./control-center/oligarchy.sh;
    executable = true;
  };
  # Guided update TUI — was missing from PATH (existed in source but never installed).
  home.file.".local/bin/oligarchy-update" = {
    source = ./control-center/oligarchy-update.sh;
    executable = true;
  };
}

{ pkgs, ... }:

# ─────────────────────────────────────────────────────────────────────────────
# Oligarchy Desktop Entries
# Makes project CLI tools discoverable in Wofi / app launchers.
# Each entry opens a themed kitty terminal running the command.
# ─────────────────────────────────────────────────────────────────────────────

{
  home.file.".local/share/applications/oligarchy.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=Oligarchy
    Comment=Command center for the War Machine
    Icon=utilities-terminal
    Exec=${pkgs.kitty}/bin/kitty --class oligarchy -e oligarchy
    Categories=System;
    Terminal=false
  '';

  home.file.".local/share/applications/oligarchy-update.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=System Update
    Comment=Guided NixOS system rearmament
    Icon=system-software-update
    Exec=${pkgs.kitty}/bin/kitty --class oligarchy-update -e oligarchy-update
    Categories=System;
    Terminal=false
  '';

  home.file.".local/share/applications/oligarchy-warroom.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=War Room
    Comment=Live system dashboard
    Icon=utilities-system-monitor
    Exec=${pkgs.kitty}/bin/kitty --class warroom -e oligarchy-warroom
    Categories=System;Monitor;
    Terminal=false
  '';

  home.file.".local/share/applications/dsp-status.desktop".text = ''
    [Desktop Entry]
    Type=Application
    Name=DSP Status
    Comment=DSP coprocessor VM status
    Icon=audio-card
    Exec=${pkgs.kitty}/bin/kitty --class dsp-status -e dsp-status
    Categories=Audio;System;
    Terminal=false
  '';
}

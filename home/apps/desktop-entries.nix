{ pkgs, lib, ... }:

let
  # Kept in sync with configuration.nix's icewm-menu launcher — see that
  # comment block for why RestrictNamespaces/SystemCallFilter/
  # MemoryDenyWriteExecute/RestrictRealtime are deliberately excluded
  # (they break Proton's pressure-vessel sandbox, Wine/Mono JIT, or
  # GameMode's realtime scheduling respectively).
  steamHardeningProps = [
    "NoNewPrivileges=yes"
    "RestrictSUIDSGID=yes"
    "ProtectHostname=yes"
    "ProtectClock=yes"
    "ProtectKernelTunables=yes"
    "ProtectKernelLogs=yes"
    "ProtectKernelModules=yes"
    "ProtectControlGroups=yes"
    # ProtectHome is deliberately absent: Steam's library lives in $HOME.
    "LockPersonality=yes"
  ];
  mkSteamExec = args:
    "${pkgs.systemd}/bin/systemd-run --user --collect --slice=steam-noswap.slice --description=steam-hardened "
    + lib.concatMapStringsSep " " (p: "-p ${p}") steamHardeningProps
    + " -- /run/current-system/sw/bin/steam" + args;
  steamExec = mkSteamExec " %U";
in

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

  # Overrides the system steam.desktop (same desktop-id, user data dir takes
  # XDG precedence) so launchers going through the desktop entry (wofi,
  # oligarchy-menu) also land in steam-noswap.slice — see configuration.nix
  # "Gaming" section for why. The IceWM menu's hardcoded launch path is
  # fixed separately there, since it bypasses desktop entries entirely.
  home.file.".local/share/applications/steam.desktop".text = ''
    [Desktop Entry]
    Name=Steam
    Comment=Valve Steam
    Icon=steam
    Exec=${steamExec}
    Terminal=false
    Type=Application
    Categories=Network;FileTransfer;Game;
    MimeType=x-scheme-handler/steam;x-scheme-handler/steamlink;
    Actions=Library;BigPicture;Friends;
    PrefersNonDefaultGPU=true
    X-KDE-RunOnDiscreteGpu=true
    StartupNotify=true
    StartupWMClass=steam

    [Desktop Action Library]
    Name=Library
    Exec=${mkSteamExec " steam://open/games"}

    [Desktop Action BigPicture]
    Name=Big Picture
    Exec=${mkSteamExec " -gamepadui"}

    [Desktop Action Friends]
    Name=Friends
    Exec=${mkSteamExec " steam://open/friends"}
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

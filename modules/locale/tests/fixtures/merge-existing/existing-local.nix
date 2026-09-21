# ~/.config/oligarchy/local.nix — hand-written, read only under --impure.
# Modelled on the maintainer's real file: a lambda header, a mix of
# custom.* and services.* toggles, and comments that must survive.
{ pkgs, lib, ... }: {
  custom.desktopFeatures = {
    enableDev = true;
    enableGaming = true;
    enableAudio = true;
  };

  services.boot-intro.enable = true;
  custom.steam.enable = true;
  custom.vm.dsp.enable = true;

  # Come back after a reboot: autologin straight into Hyprland.
  custom.session = {
    autoLogin.enable = true;
    restore.enable = true;
  };

  custom.mcpServers.enable = true;
  networking.firewall.strictEgress.enable = true;
}

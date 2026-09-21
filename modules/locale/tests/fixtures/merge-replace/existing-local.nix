# ~/.config/oligarchy/local.nix — already adopted once, from a different
# machine. The stale custom.locale block below must be replaced wholesale
# (nested `keyboard = { … };` and all), and nothing else may move.
{ pkgs, lib, ... }: {
  custom.steam.enable = true;

  custom.locale = {
    language = "de-DE";
    timeZone = "Europe/Berlin";
    keyboard = {
      layout = "de";
      variant = "nodeadkeys";
    };
  };

  custom.malwareShield.enable = true;
}

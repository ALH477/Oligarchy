# ~/.config/oligarchy/local.nix — already adopted once, from a different
# machine. The stale custom.locale block below must be replaced wholesale
# (nested `keyboard = { … };` and all), and nothing else may move.
{ pkgs, lib, ... }: {
  custom.steam.enable = true;

  custom.locale = {
    language = "ja-JP";
    timeZone = "Asia/Tokyo";
    keyboard = {
      layout = "jp";
    };
  };

  custom.malwareShield.enable = true;
}

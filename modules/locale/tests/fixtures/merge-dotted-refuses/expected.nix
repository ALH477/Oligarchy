# ~/.config/oligarchy/local.nix — hand-written, and already setting
# custom.locale in the DOTTED form. oligarchy-adopt's merge recognises only
# the block form `custom.locale = {`, so appending its fragment here would
# produce a file with `language` defined twice: every later
# `nixos-rebuild switch --flake .#nixos --impure` would then fail to
# evaluate. The tool must refuse, name these lines, and write nothing.
{ pkgs, lib, ... }: {
  custom.steam.enable = true;

  custom.locale.language = "de-DE";
  custom.locale.timeZone = "Europe/Berlin";

  custom.malwareShield.enable = true;
}

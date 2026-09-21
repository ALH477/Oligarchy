# oligarchy-adopt — packaged.
#
# docs/localization-roadmap.md §6 option (B): rather than patching Calamares to
# write a flake, read what the installer already left under /etc and emit a
# `custom.locale` fragment into ~/.config/oligarchy/local.nix — the override
# channel that already exists and that the maintainer's own machine uses.
#
# The script is `builtins.readFile`'d in rather than `exec`'d so that
# writeShellApplication runs shellcheck over it at build time; the .sh keeps
# its shebang and stays runnable standalone, which is how
# `.#locale-adopt-fixtures` and `nix develop` drive it.
{ pkgs, lib, ... }:

pkgs.writeShellApplication {
  name = "oligarchy-adopt";

  runtimeInputs = with pkgs; [
    coreutils
    gnused
    gawk
    gnugrep
  ];

  text = builtins.readFile ./oligarchy-adopt.sh;

  meta = with lib; {
    description = "Adopt an installed system's locale, keyboard and timezone into custom.locale";
    longDescription = ''
      Reads <root>/etc/locale.conf, vconsole.conf, localtime (or timezone) and
      etc/nixos/configuration.nix, and writes a custom.locale fragment into
      ~/.config/oligarchy/local.nix, merging rather than clobbering. Prints the
      --impure requirement, because without it configuration.nix silently
      ignores the file it just wrote.
    '';
    license = licenses.mit;
    platforms = platforms.linux;
    mainProgram = "oligarchy-adopt";
  };
}

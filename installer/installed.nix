# SPDX-License-Identifier: BSD-3-Clause
#
# install.json -> Oligarchy options, for a machine the ISO's installer put
# on a disk.
#
# The installer (installer/calamares/distroinstall/main.py, or the
# `oligarchy-install` CLI) writes hosts/installed/install.json from what the
# user answered; flake.nix's `mkInstalled` takes the chosen target from
# `installTargets`, drops that target's hardware file and host name, and adds
# this module plus the hardware scan. The mapping lives here, in Nix, so
# `.#installer-contract` can test it against fixtures.
#
# Only what the installer asked about is set. Everything else is the target's,
# exactly as `.#<target>` builds it. Personal settings go in
# hosts/installed/local.nix, which is imported when present and never written
# by the installer.
#
# This is what docs/localization-roadmap.md §6 rejected as option (A) and now
# does, for the reasons recorded there: the locale lands in custom.locale.*
# (its single source), not in a generic configuration.nix the flake would
# later have to adopt.
{ install }:
{ config, lib, ... }:

let
  inherit (lib) mkIf mkMerge mkForce listToAttrs nameValuePair head splitString
    replaceStrings toLower elemAt length unique attrValues optional;

  u = install.user or null;
  kb = install.keyboard or null;
  loc = install.locale or null;
  boot = install.boot;
  luks = install.luks or { swap = [ ]; keyFile = [ ]; };
  efi = boot.firmware == "efi";

  # The same two rules as oligarchy-adopt (modules/locale/oligarchy-adopt.sh):
  # every spelling of UTF-8 becomes `.UTF-8` and an @modifier is dropped
  # (custom.locale's assertion wants the canonical spelling), and the BCP-47
  # tag is the locale name with `_` -> `-` and no charset.
  normalize = l:
    let
      noMod = head (splitString "@" l);
      parts = splitString "." noMod;
      utf8 = length parts == 2
        && toLower (replaceStrings [ "-" "_" ] [ "" "" ] (elemAt parts 1)) == "utf8";
    in
    if utf8 then "${head parts}.UTF-8" else noMod;
  toBcp47 = l: replaceStrings [ "_" ] [ "-" ] (head (splitString "." (head (splitString "@" l))));
  isC = l: builtins.elem (head (splitString "." l)) [ "C" "POSIX" "" ];

  lang = if loc != null && loc ? LANG && !(isC loc.LANG) then normalize loc.LANG else null;
  # Calamares writes one "formats" locale into every LC_* key it sets.
  formats =
    let others = unique (map normalize (attrValues (removeAttrs (if loc == null then { } else loc) [ "LANG" ])));
    in if others == [ ] then null else head others;
in
{
  assertions = [{
    assertion = (install.schema or null) == 1;
    message = "hosts/installed/install.json has schema ${builtins.toJSON (install.schema or null)}; this tree reads schema 1.";
  }];

  networking.hostName = install.hostname;

  custom.locale = mkMerge [
    (mkIf (lang != null) { language = toBcp47 lang; glibcLocale = lang; })
    (mkIf (formats != null && formats != lang) { region = formats; })
    (mkIf ((install.timeZone or null) != null) { timeZone = install.timeZone; })
    # The console keymap is NOT taken from the installer: custom.locale
    # compiles it from the same xkb description (consoleKeyMap = null), which
    # is the property locale.nix exists for — TTY, LUKS prompt and Hyprland
    # cannot drift apart.
    (mkIf (kb != null) { keyboard = { layout = kb.layout; variant = kb.variant; }; })
  ];

  # The account is the user's, not the maintainer's. custom.user.name is what
  # configuration.nix creates, Home Manager configures and several modules run
  # as; the maintainer's SSH keys and git identity are the defaults in
  # modules/user.nix and must not follow the distribution onto somebody
  # else's machine. The password is set by the installer's users step (or by
  # `oligarchy-install`), never written here.
  custom.user = mkIf (u != null) {
    name = u.name;
    fullName = if (u.fullName or "") != "" then u.fullName else u.name;
    email = null;
    sshAuthorizedKeys = mkForce [ ];
  };
  custom.session.autoLogin.enable = mkIf (u != null && u.autologin) true;

  # An installed machine reads hosts/installed/local.nix, purely. The
  # ~/.config/oligarchy override channel is the maintainer's, so the pure-eval
  # advisory has nothing to warn about here.
  custom.localOverrides.expected = false;

  # configuration.nix boots with systemd-boot. A BIOS machine gets GRUB on the
  # disk the installer named.
  boot.loader = mkIf (!efi) {
    systemd-boot.enable = mkForce false;
    efi.canTouchEfiVariables = mkForce false;
    grub = {
      enable = true;
      device = boot.device;
      useOSProber = true;
      fsIdentifier = mkIf boot.btrfsRoot "provided";
      enableCryptodisk = mkIf boot.grubCryptodisk true;
    };
  };

  # Upstream's LUKS handling, from the same facts: encrypted swap that
  # nixos-generate-config cannot see, and the GRUB-cryptodisk keyfile that
  # spares a second passphrase prompt.
  boot.initrd.secrets = mkIf (luks.keyFile != [ ]) { "/boot/crypto_keyfile.bin" = null; };
  boot.initrd.luks.devices = mkMerge [
    (listToAttrs (map (s: nameValuePair s.name { device = "/dev/disk/by-uuid/${s.uuid}"; }) luks.swap))
    (listToAttrs (map (n: nameValuePair n { keyFile = "/boot/crypto_keyfile.bin"; }) luks.keyFile))
  ];
}

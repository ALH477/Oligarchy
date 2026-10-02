# installer-contract — eval-only. What the ISO's installer writes
# (hosts/installed/install.json + the hardware scan) becomes the target the
# user picked, with THEIR identity, through flake.nix's mkInstalled and
# installer/installed.nix.
#
# The fixtures under tests/fixtures/installed/ are in the layout the installer
# leaves in /etc/nixos/hosts/installed. Three full system evaluations (Home
# Manager included), so this lives in legacyPackages, like locale-contract:
# `nix flake check` never pays for it.
#
#   nix build .#installer-contract
{ pkgs, mkInstalled }:

let
  lib = pkgs.lib;
  cfg = name: (mkInstalled (../fixtures/installed + "/${name}")).config;
  fw = cfg "fw16-efi";
  intel = cfg "intel-bios-luks";
  failedAssertions = c: map (a: a.message) (lib.filter (a: !a.assertion) c.assertions);

  # Every authorized key on the machine, any account.
  allKeys = c: lib.concatMap (u: u.openssh.authorizedKeys.keys) (lib.attrValues c.users.users);
  maintainerKeys = [ "root@deepcomputing" "ubuntu@deepcomputing" "hermes@framework16" ];
  gitUser = c: user: c.home-manager.users.${user}.programs.git.settings.user;

  checks = [
    # ── anti-vacuity: the fixtures really are the targets they claim ──────
    {
      name = "fixture fw16-efi is the Framework 16 target (plugin runtime, AMD, framework)";
      ok = fw.custom.plugins.enable && fw.custom.platform.cpu == "amd" && fw.custom.platform.framework;
    }
    {
      name = "fixture intel-bios-luks is the Intel target";
      ok = intel.custom.platform.cpu == "intel" && intel.custom.platform.gpu == "intel" && !(intel.custom ? plugins);
    }

    # ── the machine is the user's ──────────────────────────────────────────
    {
      name = "host name from install.json, not the target's";
      ok = fw.networking.hostName == "werkbank" && intel.networking.hostName == "altbook";
    }
    {
      name = "the account is the installed user's, in wheel, with Home Manager";
      ok = fw.custom.user.name == "maria" && fw.users.users.maria.isNormalUser
        && lib.elem "wheel" fw.users.users.maria.extraGroups && fw.home-manager.users ? maria
        && !(fw.users.users ? asher);
    }
    {
      name = "none of the maintainer's SSH keys is authorised on an installed machine";
      ok = lib.all (c: !lib.any (k: lib.any (m: lib.hasInfix m k) maintainerKeys) (allKeys c)) [ fw intel ];
    }
    {
      name = "git identity is the user's: their name, no email (not the maintainer's)";
      ok = gitUser fw "maria" == { name = "Maria Example"; }
        && gitUser intel "sam" == { name = "sam"; };
    }
    {
      name = "the hardware scan replaces the target's hardware file";
      ok = fw.fileSystems."/".device == "/dev/disk/by-uuid/0f0f0f0f-1111-4222-8333-444444444444"
        && fw.fileSystems."/boot".device == "/dev/disk/by-uuid/ABCD-1234";
    }

    # ── locale lands in custom.locale.*, its single source ───────────────
    {
      name = "LANG de_DE.utf8 -> language de-DE, glibcLocale de_DE.UTF-8 (oligarchy-adopt's normalisation)";
      ok = fw.custom.locale.language == "de-DE" && fw.custom.locale.glibcLocale == "de_DE.UTF-8"
        && fw.i18n.defaultLocale == "de_DE.UTF-8";
    }
    {
      name = "the formats locale (LC_TIME en_GB) becomes custom.locale.region, and reaches every LC_* key";
      ok = fw.custom.locale.region == "en_GB.UTF-8" && fw.i18n.extraLocaleSettings.LC_TIME == "en_GB.UTF-8"
        && fw.i18n.extraLocaleSettings.LC_PAPER == "en_GB.UTF-8";
    }
    {
      name = "no formats locale distinct from LANG -> region stays null";
      ok = intel.custom.locale.region == null && intel.custom.locale.language == "en-US";
    }
    {
      name = "time zone and keyboard via custom.locale; xkb reads them";
      ok = fw.custom.locale.timeZone == "Europe/Berlin" && fw.time.timeZone == "Europe/Berlin"
        && fw.services.xserver.xkb.layout == "de" && fw.services.xserver.xkb.variant == "nodeadkeys";
    }
    {
      name = "the console keymap is derived from xkb, not taken from Calamares";
      ok = fw.custom.locale.keyboard.consoleKeyMap == null && fw.console.keyMap != "de-latin1-nodeadkeys";
    }

    # ── boot ───────────────────────────────────────────────────────────────
    {
      name = "UEFI: systemd-boot, as configuration.nix has it";
      ok = fw.boot.loader.systemd-boot.enable && !fw.boot.loader.grub.enable;
    }
    {
      name = "BIOS: GRUB on the named disk with cryptodisk, systemd-boot off, EFI variables untouched";
      ok = intel.boot.loader.grub.enable && intel.boot.loader.grub.device == "/dev/sda"
        && intel.boot.loader.grub.enableCryptodisk && intel.boot.loader.grub.fsIdentifier == "provided"
        && !intel.boot.loader.systemd-boot.enable && !intel.boot.loader.efi.canTouchEfiVariables;
    }
    {
      name = "LUKS: encrypted swap declared, the keyfile on every LUKS device";
      ok = intel.boot.initrd.luks.devices.luks-swap.device == "/dev/disk/by-uuid/22222222-0000-4000-8000-000000000002"
        && intel.boot.initrd.luks.devices.luks-root.keyFile == "/boot/crypto_keyfile.bin"
        && intel.boot.initrd.secrets ? "/boot/crypto_keyfile.bin";
    }

    # ── the rest ───────────────────────────────────────────────────────────
    {
      name = "autologin goes through Oligarchy's own greetd path (custom.session.autoLogin)";
      ok = intel.custom.session.autoLogin.enable && !fw.custom.session.autoLogin.enable;
    }
    {
      name = "no pure-eval override advisory: an installed machine reads hosts/installed/local.nix";
      ok = !fw.custom.localOverrides.expected && !lib.any (lib.hasInfix "custom.localOverrides.expected") fw.warnings;
    }
    {
      name = "an install.json schema this tree does not read fails an assertion";
      ok = lib.any (lib.hasInfix "schema 2") (failedAssertions (cfg "bad-schema"));
    }
    {
      name = "both installs evaluate with no failed assertion";
      ok = failedAssertions fw == [ ] && failedAssertions intel == [ ];
    }
  ];

  failed = lib.filter (x: !x.ok) checks;
  report = lib.concatMapStringsSep "\n" (x: (if x.ok then "PASS: " else "FAIL: ") + x.name) checks;
in
pkgs.runCommand "installer-contract" { inherit report; passAsFile = [ "report" ]; } ''
  cat "$reportPath"; echo
  echo "${toString (lib.length checks - lib.length failed)}/${toString (lib.length checks)} checks passed"
  ${if failed == [ ] then ''cp "$reportPath" $out'' else "exit 1"}
''

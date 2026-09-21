# custom.locale — the one place this distribution decides what language,
# keyboard, timezone and fonts it is.
#
# Before this file, locale was decided in six places and three of them were an
# unmarked mirror: `services.xserver.xkb` in configuration.nix, `kb_layout` in
# home/hyprland, and (the moment anyone set it) `console.keyMap`. Set a German
# layout in one and the others silently kept `us` — including the IceWM
# recovery session and the LUKS passphrase prompt, i.e. the two you reach when
# things are already on fire. See docs/localization-roadmap.md §3.1.
#
# Decisions, not defaults:
# - **No `enable`.** Every machine has a locale; this module has no off state.
#   What it has instead is defaults equal to the values that were hardcoded
#   before it existed, so landing it is a no-op diff on every host. It adds no
#   unit, no timer and no package beyond the fonts `fonts.autoInstall` already
#   gates to the selected language, which is why the ISO needs no `mkForce`
#   for it.
# - **`language` is BCP-47, not a glibc locale string.** Three consumers want
#   three spellings of the same idea (`de-DE` for the catalog and the Piper
#   voice, `de_DE.UTF-8` for glibc, `de` for xkb and Whisper). Picking glibc's
#   spelling as canonical would put `_` and `.UTF-8` into catalog filenames.
#   The translation lives in modules/locale/lib.nix.
# - **`region` is separate from `language`** because "English UI, metric units,
#   ISO dates" is the single most common real configuration, and collapsing
#   the two would mistranslate the UI to get the date format right.
# - **The console keymap is DERIVED, not duplicated.** `ckbcomp` compiles the
#   same xkb description the desktop uses into a vconsole keymap, so the TTY
#   and the LUKS prompt cannot disagree with Hyprland. That is the mirror
#   killed by derivation rather than by a gate. Cost: `pkgs.ckbcomp` (perl)
#   enters the build closure and one small derivation is built per distinct
#   layout. `keyboard.consoleKeyMap` is the escape hatch for a keymap xkb
#   cannot express.
#
#   NOT via `console.useXkbConfig`, deliberately. That switch is nixpkgs'
#   mechanism for the same idea, but its implementation
#   (nixos/modules/config/console.nix) defines `console.keyMap` at NORMAL
#   priority under `mkIf cfg.useXkbConfig`. Turning it on therefore makes an
#   ordinary `console.keyMap = "de-latin1";` in local.nix a hard eval
#   *conflict*, with an error that points into nixpkgs and never mentions
#   `custom.locale`. So `useXkbConfig` stays at its default (false) and this
#   module builds the identical `xkb-console-keymap` derivation itself, at
#   `mkDefault`. Same keymap, same source values, and a plain user
#   `console.keyMap` line simply wins.
# - **Every sink below is `mkDefault`**, so `~/.config/oligarchy/local.nix`
#   overrides all of it with no new override channel. That file needs
#   `--impure`: without it `builtins.pathExists` answers false rather than
#   erroring and your overrides are silently ignored, the same trap as every
#   other local toggle in this tree.
#
# What this does NOT do (yet):
# - `strings.*` is DECLARED here and read by nothing. Stage 3 of the roadmap
#   renders first-party UI strings from modules/locale/catalog/; until then the
#   menus are English whatever `language` says. The option exists now so that
#   stages 3-5 compile against a frozen contract.
# - It does not touch the Whisper/Piper voice models (stage 5) and does not
#   translate any documentation (§2.1: non-goals).
{ config, lib, pkgs, ... }:

with lib;

let
  cfg = config.custom.locale;
  localeLib = import ./locale/lib.nix { inherit lib; };

  # The nine format keys. LC_MESSAGES and LC_COLLATE are deliberately absent:
  # those follow the UI language (i18n.defaultLocale), not the region.
  formatKeys = [
    "LC_ADDRESS"
    "LC_IDENTIFICATION"
    "LC_MEASUREMENT"
    "LC_MONETARY"
    "LC_NAME"
    "LC_NUMERIC"
    "LC_PAPER"
    "LC_TELEPHONE"
    "LC_TIME"
  ];

  formatsLocale = if cfg.region == null then cfg.glibcLocale else cfg.region;

  # Replicated from nixos/modules/config/console.nix (25.11) rather than
  # reached via `console.useXkbConfig` — see the header for why the switch is
  # unusable here. One deliberate difference: it reads `cfg.keyboard.*`
  # directly instead of `config.services.xserver.xkb.*`, so the keymap does not
  # take a hop through another module's fixpoint to get values this module set
  # in the first place. The divergence assertion below is what keeps the two
  # from drifting when someone sets `services.xserver.xkb` by hand.
  xkbConsoleKeymap = pkgs.runCommand "xkb-console-keymap" { preferLocalBuild = true; } ''
    '${pkgs.buildPackages.ckbcomp}/bin/ckbcomp' \
      ${
      optionalString (
        config.environment.sessionVariables ? XKB_CONFIG_ROOT
      ) "-I${config.environment.sessionVariables.XKB_CONFIG_ROOT}"
    } \
      -model '${cfg.keyboard.model}' -layout '${cfg.keyboard.layout}' \
      -option '${cfg.keyboard.options}' -variant '${cfg.keyboard.variant}' > "$out"
  '';

  # Hyprland reads custom.locale.keyboard.* directly while the console keymap
  # and X11 read it through services.xserver.xkb, so a direct
  # `services.xserver.xkb.layout = "de"` gives a German X session and a US
  # Hyprland session with nothing logged — the exact mirror this module exists
  # to remove, recreated one option lower down.
  xkbKeys = [ "layout" "variant" "options" "model" ];
  divergentXkbKeys = filter (k: config.services.xserver.xkb.${k} != cfg.keyboard.${k}) xkbKeys;

  # An input method with no addon installs the framework and no engine: fcitx5
  # comes up, the candidate window never appears, and the script cannot be
  # typed at all. Keyed on the primary subtag because the engine follows the
  # language, not the region. `yue` is here because localeLib.isCJK counts it,
  # so a `yue-HK` language auto-enables fcitx5 and would otherwise land in the
  # zero-addon hole this exists to close.
  #
  # NB `pkgs.fcitx5-chinese-addons` is an alias that THROWS on 25.11 — the
  # package lives under qt6Packages, which is also where nixpkgs' own fcitx5
  # module takes fcitx5-with-addons from.
  fcitx5AddonsFor =
    tag:
    let
      lang = localeLib.primarySubtag tag;
    in
    if lang == "ja" then
      [ pkgs.fcitx5-mozc ]
    else if lang == "zh" || lang == "yue" then
      [ pkgs.qt6Packages.fcitx5-chinese-addons ]
    else if lang == "ko" then
      [ pkgs.fcitx5-hangul ]
    else
      [ ];

  # fcitx5 for Chinese/Japanese/Korean, nothing otherwise. An input method is
  # not optional for those languages — without one there is no way to type the
  # script at all — and it is pure overhead for the rest.
  resolvedInputMethod =
    if cfg.inputMethod != null then
      cfg.inputMethod
    else if localeLib.isCJK cfg.language then
      "fcitx5"
    else
      null;

  # CJK coverage is needed when the UI language is CJK *or* when the user reads
  # English but has Japanese filenames — the case a language-only rule misses.
  # extraLocales entries carry a charset suffix ("ja_JP.UTF-8/UTF-8"), hence
  # the prefix test rather than an equality test.
  needsCjkFonts =
    localeLib.isCJK cfg.language
    || (
      isList cfg.extraLocales
      && any (entry: any (p: hasPrefix p entry) [ "ja_" "zh_" "ko_" ]) cfg.extraLocales
    );

  # noto-fonts alone already carries Arabic, Hebrew, Greek, Cyrillic and
  # Devanagari coverage; it does NOT carry CJK, which ships as two separate
  # packages. So the base set is language-independent and only CJK is
  # conditional. Without this a Japanese locale renders tofu in kitty, waybar,
  # wofi and every GTK/Qt app — see docs/localization-roadmap.md §3.3.
  baseFonts = [
    pkgs.noto-fonts
    pkgs.noto-fonts-color-emoji
  ];

  scriptFonts = optionals needsCjkFonts [
    pkgs.noto-fonts-cjk-sans
    pkgs.noto-fonts-cjk-serif
  ];

  # Heuristic, and only ever used to decide whether to print a WARNING: a user
  # may legitimately be carrying CJK coverage in a package this does not
  # recognise.
  hasCjkFontAlready = any
    (
      p:
      let
        n = toLower (baseNameOf (toString p));
      in
      hasInfix "cjk" n || hasInfix "han" n
    )
    config.fonts.packages;

  # Stage 3 replaces this with the key set of modules/locale/catalog/*.json.
  # Hardcoded to the one catalog that exists today so the assertion below is
  # real rather than aspirational.
  catalogLanguages = [ "en" ];

  catalogFor =
    tag:
    if elem tag catalogLanguages then
      tag
    else if elem (localeLib.primarySubtag tag) catalogLanguages then
      localeLib.primarySubtag tag
    else
      null;
in
{
  options.custom.locale = {
    language = mkOption {
      type = types.str;
      default = "en-US";
      example = "de-DE";
      description = ''
        UI language as a BCP-47 tag. Drives the glibc locale (via
        {option}`custom.locale.glibcLocale`), the message catalog selected from
        `modules/locale/catalog/`, the Whisper/Piper voice models, and the
        default font set. `"xx-pseudo"` is reserved for the `.#i18n-pseudo`
        gate.
      '';
    };

    glibcLocale = mkOption {
      type = types.str;
      default = localeLib.bcp47ToGlibc cfg.language;
      defaultText = literalMD "derived from `custom.locale.language`";
      example = "de_DE.UTF-8";
      description = ''
        Escape hatch for tags glibc spells differently (`pt-BR`,
        `zh-Hans-CN`, `sr-Latn-RS`). Set this when the assertion tells you the
        derived name is not one glibc can generate — the silent failure mode
        otherwise is glibc falling back to `C`, changing sort order and month
        names with nothing logged.
      '';
    };

    region = mkOption {
      type = types.nullOr types.str;
      default = null; # null => same as glibcLocale
      example = "de_AT.UTF-8";
      description = ''
        Formats locale: the nine `LC_*` keys for address/identification/
        measurement/monetary/name/numeric/paper/telephone/time. Split from
        {option}`custom.locale.language` because "English UI, metric units,
        ISO dates" is the single most common real configuration, and forcing
        it through `language` would mistranslate the UI to get it.

        A glibc locale name, not a BCP-47 tag, and with no `/CHARSET` suffix.
        `null` means "same as {option}`custom.locale.glibcLocale`".
      '';
    };

    timeZone = mkOption {
      type = types.str;
      default = "America/Los_Angeles";
      example = "Europe/Berlin";
      description = "System timezone, as an IANA zone name from `tzdata`.";
    };

    keyboard = {
      layout = mkOption {
        type = types.str;
        default = "us";
        example = "de";
        description = ''
          Keyboard layout in xkb spelling. Reaches the Wayland session, the
          IceWM/X11 recovery session and — via the derived
          {option}`console.keyMap` — the TTY and the initrd LUKS prompt, from
          this one value.

          Set THIS, never {option}`services.xserver.xkb.layout` directly: the
          Hyprland session reads this option while the console keymap and X11
          read it through `services.xserver.xkb`, so setting the sink diverges
          them. An assertion refuses that configuration rather than letting it
          boot half-German.
        '';
      };

      variant = mkOption {
        type = types.str;
        default = "";
        example = "nodeadkeys";
        description = "xkb layout variant, or the empty string for none.";
      };

      options = mkOption {
        type = types.str;
        default = "caps:escape";
        example = "caps:escape,compose:ralt";
        description = "xkb options, comma-separated.";
      };

      model = mkOption {
        type = types.str;
        default = "pc105";
        example = "pc104";
        description = ''
          xkb keyboard model. Note this differs from the nixpkgs default
          (`pc104`); `pc105` is the ISO/ANSI-superset model and is what the
          derived console keymap is compiled against.
        '';
      };

      consoleKeyMap = mkOption {
        type = types.nullOr (types.either types.str types.path);
        default = null;
        example = "de-latin1-nodeadkeys";
        description = ''
          Override the virtual-console keymap instead of deriving it from the
          xkb description above.

          `null` (the default) is the right answer almost always: the module
          then compiles the SAME xkb description the desktop uses into a
          vconsole keymap with `ckbcomp` and sets it as
          {option}`console.keyMap` at `mkDefault`, so the TTY and the LUKS
          prompt cannot drift away from Hyprland. Setting this reintroduces
          that mirror by hand — do it only for a keymap xkb cannot express.

          Either way {option}`console.useXkbConfig` is left alone (false), so
          a plain `console.keyMap = "de-latin1";` elsewhere in your config just
          overrides the default instead of colliding with nixpkgs.
        '';
      };
    };

    inputMethod = mkOption {
      type = types.nullOr (types.enum [ "ibus" "fcitx5" "nabi" "uim" "hime" "kime" ]);
      default = null;
      example = "fcitx5";
      description = ''
        Input-method framework. `null` (the default) auto-selects: `fcitx5`
        for a Chinese/Japanese/Korean {option}`custom.locale.language`, none
        otherwise. Set explicitly to force one on or — with
        {option}`i18n.inputMethod.enable` — off.

        Resolving to `fcitx5` also installs the engine addon for the language
        (`fcitx5-mozc` for `ja`, `fcitx5-chinese-addons` for `zh`/`yue`,
        `fcitx5-hangul` for `ko`) — without one, fcitx5 starts and still
        cannot type the script. There is deliberately no
        `custom.locale.inputMethodAddons` option: set
        {option}`i18n.inputMethod.fcitx5.addons` directly. That option is a
        merging list, so your entries are ADDED to the derived one; use
        `lib.mkForce` to replace it outright. (It cannot be `mkDefault` here —
        nixpkgs' own fcitx5 module already defines it at normal priority, so a
        `mkDefault` list would be silently discarded.)
      '';
    };

    extraLocales = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [ "nl_NL.UTF-8/UTF-8" "ja_JP.UTF-8/UTF-8" ];
      description = ''
        Additional locales to generate, beyond the ones implied by
        {option}`custom.locale.glibcLocale` and
        {option}`custom.locale.region`.

        The `/CHARSET` suffix is REQUIRED here and forbidden in
        {option}`custom.locale.region` — the two options take different
        shapes, and mixing them is a silent miss. A `ja_`/`zh_`/`ko_` entry
        also pulls the CJK fonts in, for the user who reads English but has
        Japanese filenames.
      '';
    };

    fonts.autoInstall = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Install a system-level font set covering the selected language. Before
        this module `fonts.packages` was set nowhere in the tree: every font
        came from Home Manager, so the greeter — which runs as the system user
        `greeter` with no Home Manager profile — had none at all.
      '';
    };

    fonts.extraPackages = mkOption {
      type = types.listOf types.package;
      default = [ ];
      example = literalExpression "[ pkgs.source-han-sans ]";
      description = ''
        Extra font packages to install alongside the automatic set. Always
        applied, including with {option}`custom.locale.fonts.autoInstall` off:
        `autoInstall` gates only the language-derived set, so turning it off
        cannot silently drop fonts you named here.
      '';
    };

    strings.enable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Render first-party UI strings from the message catalog instead of the
        English literals.

        DECLARED ONLY at this stage — nothing in this module's `config` reads
        it except the catalog-existence assertion. Stage 3 of
        docs/localization-roadmap.md is what makes it do anything.
      '';
    };

    strings.fallbackLanguage = mkOption {
      type = types.str;
      default = "en";
      example = "de";
      description = ''
        Catalog to fall back to for keys the selected language has not
        translated. DECLARED ONLY at this stage; see
        {option}`custom.locale.strings.enable`.
      '';
    };
  };

  config = {
    time.timeZone = mkDefault cfg.timeZone;

    i18n.defaultLocale = mkDefault cfg.glibcLocale;

    # NB: no /CHARSET suffix here. nixos/modules/config/i18n.nix rejects the
    # idea explicitly — the suffix belongs in i18n.extraLocales, and per-key
    # charsets go in i18n.localeCharsets.
    #
    # The mkDefault is INSIDE genAttrs, one per key, not around the attrset.
    # Wrapping the whole set gives the priority to the set: a user overriding
    # LC_TIME alone then wins the whole definition and silently drops the other
    # eight keys back to i18n.defaultLocale. Per-key, the other eight survive.
    i18n.extraLocaleSettings = genAttrs formatKeys (_: mkDefault formatsLocale);

    # i18n.supportedLocales is NOT set: on 25.11 its default is derived from
    # defaultLocale + extraLocaleSettings + extraLocales, so it already tracks
    # everything above. extraLocales is the supported lever for "also generate
    # ja_JP.UTF-8". See docs/localization-roadmap.md §3.2.
    i18n.extraLocales = mkDefault cfg.extraLocales;

    # Set UNCONDITIONALLY, not under `mkIf config.services.xserver.enable`:
    # the IceWM/X11 recovery session enables X late and reads these, and the
    # divergence assertion below compares against them on every host, X or not.
    # (The derived console keymap does NOT come through here — it is compiled
    # from cfg.keyboard.* directly, so it works on a Wayland box regardless.)
    services.xserver.xkb = {
      layout = mkDefault cfg.keyboard.layout;
      variant = mkDefault cfg.keyboard.variant;
      options = mkDefault cfg.keyboard.options;
      model = mkDefault cfg.keyboard.model;
    };

    # console.useXkbConfig is deliberately NOT set — see the header. The
    # derivation below is nixpkgs' own, built from cfg.keyboard.* instead, and
    # mkDefault means an ordinary `console.keyMap = "de-latin1";` wins.
    console.keyMap = mkDefault (
      if cfg.keyboard.consoleKeyMap != null then cfg.keyboard.consoleKeyMap else xkbConsoleKeymap
    );

    # 25.11 shape: `enable` + `type`. `i18n.inputMethod.enabled` is deprecated
    # and warns.
    i18n.inputMethod = mkIf (resolvedInputMethod != null) {
      enable = mkDefault true;
      type = mkDefault resolvedInputMethod;
      fcitx5.waylandFrontend = mkIf (resolvedInputMethod == "fcitx5") (mkDefault true);

      # Normal priority, NOT mkDefault: nixpkgs' fcitx5 module defines this
      # list at normal priority whenever fcitx5 is enabled, and filterOverrides
      # keeps only the lowest-numbered priority — so an mkDefault list here
      # evaluates to [ ] and the user gets a framework with no engine, which is
      # the bug this is closing. Lists merge, so a user's own addons are added;
      # lib.mkForce replaces.
      fcitx5.addons = mkIf (resolvedInputMethod == "fcitx5") (fcitx5AddonsFor cfg.language);
    };

    # `fonts.packages` is a merging list, so no mkIf: the derived set is gated
    # by autoInstall, the user's extraPackages never are. Wrapping both in one
    # mkIf made extraPackages vanish with autoInstall = false — a silent drop.
    fonts.packages = optionals cfg.fonts.autoInstall (baseFonts ++ scriptFonts) ++ cfg.fonts.extraPackages;
    fonts.enableDefaultPackages = mkDefault true;

    assertions = [
      {
        assertion = localeLib.isWellFormedGlibcLocale cfg.glibcLocale;
        message = ''
          custom.locale.language = "${cfg.language}" maps to the glibc locale
          "${cfg.glibcLocale}", which is not a name glibc can generate.

          Set custom.locale.glibcLocale explicitly to the spelling glibc uses
          (see `localedata/SUPPORTED` in the glibc source tree), e.g.

            custom.locale.glibcLocale = "sr_RS.UTF-8@latin";

          Leaving it wrong is silent: glibc falls back to the C locale, sort
          order and month names change, and nothing logs it.

          Locales this tree has verified against glibc's localedata:
          ${concatStringsSep " " localeLib.knownGlibcLocales}
        '';
      }
      {
        assertion = cfg.region == null || localeLib.isWellFormedGlibcLocale cfg.region;
        message = ''
          custom.locale.region = "${toString cfg.region}" is not a glibc locale
          name. It takes a glibc spelling such as "de_AT.UTF-8" — NOT a BCP-47
          tag ("de-AT"), and NOT the "/CHARSET"-suffixed form that
          custom.locale.extraLocales takes. Same silent fallback to C as above.
        '';
      }
      {
        assertion = divergentXkbKeys == [ ];
        message = ''
          ${concatMapStringsSep "\n" (k: ''
          services.xserver.xkb.${k} was set directly (value "${toString config.services.xserver.xkb.${k}}")
          but custom.locale.keyboard.${k} is "${toString cfg.keyboard.${k}}"; the console keymap,
          Hyprland and X11 all read custom.locale.keyboard.*, so set that instead.'') divergentXkbKeys}

          custom.locale sets services.xserver.xkb from custom.locale.keyboard.*
          at mkDefault, so overriding the sink wins for X11 — and does nothing
          at all for the Hyprland session or the derived console keymap, both
          of which read custom.locale.keyboard.* directly. That is the mirror
          this module exists to remove, one option lower down.
        '';
      }
      {
        # Stage 3 replaces `catalogLanguages` with the real catalog directory.
        # Falling back silently to English is wrong in exactly this one case,
        # because the user asked for a language by name.
        assertion = !cfg.strings.enable || catalogFor cfg.language != null;
        message = ''
          custom.locale.strings.enable is true but there is no message catalog
          for custom.locale.language = "${cfg.language}".

          Available catalogs: ${concatStringsSep " " catalogLanguages}

          Either add modules/locale/catalog/${localeLib.primarySubtag cfg.language}.json
          or leave custom.locale.strings.enable = false, which keeps the
          first-party UI in English while the rest of custom.locale.* still
          applies.
        '';
      }
    ];

    warnings =
      optional (resolvedInputMethod != null && !cfg.fonts.autoInstall && !hasCjkFontAlready) ''
        custom.locale.inputMethod resolves to "${resolvedInputMethod}" but
        custom.locale.fonts.autoInstall is false and no CJK font was found in
        fonts.packages. An input method with no font to render its candidate
        window shows tofu. Add one to custom.locale.fonts.extraPackages or to
        fonts.packages, or set fonts.autoInstall = true.
      ''
      ++ optional (cfg.language == "xx-pseudo") ''
        custom.locale.language = "xx-pseudo" is the pseudo-locale reserved for
        the .#i18n-pseudo gate, not a language. It maps to en_US.UTF-8 for
        glibc and (from stage 3) renders every catalogued string bracketed and
        padded so unlocalized literals stand out. This is not a configuration
        you want on a real machine.
      '';
  };
}

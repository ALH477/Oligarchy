# modules/locale/lib.nix — pure locale helpers. No `pkgs`, no `config`, no IFD.
#
# Three consumers need three spellings of the same idea: `de-DE` for the message
# catalog and the Piper voice, `de_DE.UTF-8` for glibc, `de` for xkb and
# Whisper. This file owns the translation between them so the mapping lives in
# exactly one place, and so `modules/locale.nix`, the `.#locale-contract` gate
# and (later) `oligarchy-adopt` cannot disagree about it.
#
# Decisions:
# - The BCP-47 -> glibc map is an EXPLICIT table plus a generic `ll-CC` ->
#   `ll_CC.UTF-8` passthrough. The passthrough is right for most of the world
#   and wrong for exactly the cases the table lists, which is why the table
#   exists rather than a clever rule.
# - `knownGlibcLocales` is the table's targets, NOT glibc's own
#   `localedata/SUPPORTED`. Reading the real list would mean reading a file out
#   of `pkgs.glibcLocales`' output at eval time, i.e. import-from-derivation:
#   every `nix flake show`, every `nixos-rebuild --dry-run`, every pure-eval
#   gate would have to build glibc first. Verified by hand against
#   `glibc-2.42-67/share/i18n/locales` instead — every target below exists
#   there. The module therefore asserts on the SHAPE of the derived name
#   (`isWellFormedGlibcLocale`) and uses `knownGlibcLocales` only to say, in
#   the failure message, which tags are known-good.
# - `sr-Latn-RS` is deliberately ABSENT. glibc spells that locale `sr_RS@latin`
#   in `SUPPORTED` and `sr_RS.utf8@latin` at runtime — the codeset comes
#   BEFORE the modifier, so neither `sr_RS@latin.UTF-8` nor the
#   `<name>/<charset>` pair NixOS derives from `i18n.defaultLocale` lines up
#   with the other spellings the way every other entry here does. Rather than
#   guess, the tag falls through to the generic rule, fails the shape
#   assertion, and tells the user to set `custom.locale.glibcLocale` by hand.
{ lib }:

let
  inherit (lib) elem toUpper;

  # Tags glibc spells differently from the naive `ll-CC` -> `ll_CC` rule, plus
  # the common tags written out so the mapping is greppable and testable.
  # Every value verified present in glibc 2.42's localedata.
  bcp47Table = {
    "en-US" = "en_US.UTF-8";
    "en-GB" = "en_GB.UTF-8";
    "en-CA" = "en_CA.UTF-8";
    "en-AU" = "en_AU.UTF-8";
    "en-PH" = "en_PH.UTF-8";
    "de-DE" = "de_DE.UTF-8";
    "de-AT" = "de_AT.UTF-8";
    "de-CH" = "de_CH.UTF-8";
    "fr-FR" = "fr_FR.UTF-8";
    "fr-CA" = "fr_CA.UTF-8";
    "es-ES" = "es_ES.UTF-8";
    "es-MX" = "es_MX.UTF-8";
    "pt-BR" = "pt_BR.UTF-8";
    "pt-PT" = "pt_PT.UTF-8";
    "it-IT" = "it_IT.UTF-8";
    "nl-NL" = "nl_NL.UTF-8";
    "sv-SE" = "sv_SE.UTF-8";
    "nb-NO" = "nb_NO.UTF-8";
    "da-DK" = "da_DK.UTF-8";
    "fi-FI" = "fi_FI.UTF-8";
    "pl-PL" = "pl_PL.UTF-8";
    "cs-CZ" = "cs_CZ.UTF-8";
    "ru-RU" = "ru_RU.UTF-8";
    "uk-UA" = "uk_UA.UTF-8";
    "tr-TR" = "tr_TR.UTF-8";
    "el-GR" = "el_GR.UTF-8";
    "he-IL" = "he_IL.UTF-8";
    "ar-SA" = "ar_SA.UTF-8";
    "ar-EG" = "ar_EG.UTF-8";
    "ja-JP" = "ja_JP.UTF-8";
    "zh-CN" = "zh_CN.UTF-8";
    "zh-TW" = "zh_TW.UTF-8";
    "zh-HK" = "zh_HK.UTF-8";
    "ko-KR" = "ko_KR.UTF-8";
    "hi-IN" = "hi_IN.UTF-8";
    "th-TH" = "th_TH.UTF-8";
    "vi-VN" = "vi_VN.UTF-8";
    "id-ID" = "id_ID.UTF-8";

    # Script-subtagged Chinese. The generic rule cannot reach these: it would
    # have to know that Hans implies CN/SG and Hant implies TW/HK.
    "zh-Hans-CN" = "zh_CN.UTF-8";
    "zh-Hans-SG" = "zh_SG.UTF-8";
    "zh-Hant-TW" = "zh_TW.UTF-8";
    "zh-Hant-HK" = "zh_HK.UTF-8";

    # The pseudo-locale used by the .#i18n-pseudo gate. Pseudo-localization is
    # a STRING-layer trick (see docs/localization-roadmap.md §5.5); glibc has
    # no such locale and never will, so the gate build must still get a real,
    # generatable locale out of this tag or it would trip the module's own
    # shape assertion before it ever reached the strings it exists to check.
    "xx-pseudo" = "en_US.UTF-8";
  };

  # Generic BCP-47 `ll-CC` passthrough. Returns null when the tag is not of
  # that shape (a script subtag, a numeric UN M.49 region, junk), so the caller
  # can fall through to a last-resort guess the module's assertion rejects
  # loudly rather than silently inventing a locale glibc does not have.
  genericGlibc =
    tag:
    let
      m = builtins.match "([a-z]{2,3})-([A-Za-z]{2})" tag;
    in
    if m == null then null else "${builtins.elemAt m 0}_${toUpper (builtins.elemAt m 1)}.UTF-8";

  cjkLanguages = [ "ja" "zh" "ko" "yue" ];
  rtlLanguages = [ "ar" "he" "fa" "ur" ];

  # Locales whose LC_TIME is 12-hour. Short on purpose: the rest of the world
  # is 24-hour, and a wrong entry here only mis-formats a waybar clock that the
  # user can override.
  twelveHourLocales = [ "en_US" "en_PH" "en_CA" ];

  # `en_US.UTF-8`, `sr_RS.UTF-8@latin`, `de_DE` -> `en_US`, `sr_RS`, `de_DE`.
  baseName = s: builtins.head (builtins.split "[.@]" s);
in
rec {
  # The table's targets, de-duplicated and sorted. NOT glibc's `SUPPORTED`
  # (see the header) — this is the "known-good" set the module names in its
  # assertion message, never the set it validates against.
  knownGlibcLocales = lib.naturalSort (lib.unique (lib.attrValues bcp47Table));

  # "de-DE" -> "de". Also "zh-Hant-TW" -> "zh" and "de_DE.UTF-8" -> "de", so a
  # caller that has a glibc locale rather than a tag still gets a sane answer.
  primarySubtag =
    tag:
    let
      m = builtins.match "([A-Za-z]{2,3}).*" tag;
    in
    if m == null then tag else lib.toLower (builtins.elemAt m 0);

  # BCP-47 tag -> glibc locale name, including the `.UTF-8` codeset. Unknown
  # tags of the shape `ll-CC` pass through; anything else gets a best-effort
  # guess that `isWellFormedGlibcLocale` is expected to reject.
  bcp47ToGlibc =
    tag:
      bcp47Table.${tag} or (
        let
          generic = genericGlibc tag;
        in
        if generic != null then generic else "${lib.replaceStrings [ "-" ] [ "_" ] tag}.UTF-8"
      );

  # Shape check, not a membership check — see the header for why the real
  # `SUPPORTED` list is not reachable without IFD. Accepts `ll_CC.UTF-8`,
  # `ll.UTF-8` (glibc has a handful: `eo`, `tt`), and both orderings of a
  # `@modifier` suffix, because glibc writes `sr_RS.utf8@latin` at runtime
  # while some documentation writes `sr_RS@latin.UTF-8`. `C.UTF-8` is allowed
  # for completeness; nothing here generates it.
  isWellFormedGlibcLocale =
    locale:
    locale == "C.UTF-8"
    || builtins.match "[a-z]{2,3}(_[A-Z]{2})?(@[a-z]+)?\\.UTF-8" locale != null
    || builtins.match "[a-z]{2,3}(_[A-Z]{2})?\\.UTF-8(@[a-z]+)?" locale != null;

  # Coarse script family of a tag's language subtag. Used to pick fonts; the
  # answer only has to be right about which Noto package is needed.
  scriptOf =
    tag:
    let
      lang = primarySubtag tag;
    in
    if elem lang cjkLanguages then
      "cjk"
    else if elem lang [ "ar" "fa" "ur" "ps" "sd" ] then
      "arabic"
    else if elem lang [ "he" "yi" ] then
      "hebrew"
    else if elem lang [ "ru" "uk" "bg" "mk" "be" "kk" "ky" "mn" ] then
      "cyrillic"
    else if lang == "el" then
      "greek"
    else if elem lang [ "hi" "mr" "ne" "sa" ] then
      "devanagari"
    else if lang == "th" then
      "thai"
    else
      "latin";

  isCJK = tag: elem (primarySubtag tag) cjkLanguages;

  isRTL = tag: elem (primarySubtag tag) rtlLanguages;

  # 24-hour clock?  Accepts a BCP-47 tag, a glibc locale, or a whole
  # `custom.locale`-shaped attrset, because callers reach it holding different
  # things and a signature mismatch between two modules that cannot see each
  # other is exactly the silent mirror this file exists to prevent.
  #
  # NOTE: `home/waybar/default.nix` deliberately keeps its OWN two-entry table
  # rather than importing this, so `home/` still evaluates standalone on a
  # fresh clone where this NixOS module is absent — and it omits `en-US` on
  # purpose so the stage-1 rebuild does not flip this machine's clock. If you
  # ever make home/ import this file, read that comment first: the two are not
  # meant to agree yet.
  #
  #   use24h "de-DE"                                  => true
  #   use24h "en_US.UTF-8"                            => false
  #   use24h { language = "en-US"; region = "de_DE.UTF-8"; }  => true
  #
  # `region` wins when set, because it is the formats locale and LC_TIME is a
  # format. Defaults to the language when absent.
  use24h =
    arg:
    let
      effective =
        if builtins.isString arg then
          arg
        else if (arg.region or null) != null then
          arg.region
        else
          arg.glibcLocale or (bcp47ToGlibc (arg.language or "en-US"));
      # A bare BCP-47 tag has a `-`; a glibc locale has `_` or nothing.
      asGlibc = if builtins.match ".*-.*" effective != null then bcp47ToGlibc effective else effective;
    in
      !(elem (baseName asGlibc) twelveHourLocales);
}

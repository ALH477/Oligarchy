# Localization (i18n/l10n) — Design & Living Roadmap

> **Status:** LIVING DOCUMENT. **Stages 0, 1 and 2 landed 2026-09-21** on
> branch `feat/locale-day-one` — that is the §10 day-one cut: the `custom.locale.*`
> contract, the system layer behind it, and `oligarchy-adopt`. The §4.1 option
> names are therefore **frozen, not proposed**. Stages 3-5 (every catalog, every
> `t!()`, voice) are untouched and everything this document says about them is
> still a proposal, as are the four gates that serve them
> (`.#catalog-drift`, `.#i18n-pseudo`, `.#test-iso-locale-roundtrip`,
> `.#locale-voice-contract`). §3 remains the measured part, measured against the
> tree at commit `76674a9`. Update the stage table and the changelog at the
> bottom as work proceeds. The design section above the line is the contract;
> the roadmap below the line is the work tracker.
>
> **Source:** no sub-flake. The contract lives in `modules/locale.nix` +
> `modules/locale/` (the adoption tool and its fixtures; catalogs and
> generators when stage 3 lands) in the main tree, wired into `commonModules`
> alongside `./modules/platform.nix` and `./modules/user.nix`, which it
> deliberately imitates.

---

## 1. Purpose

Make this distribution installable and usable by someone who is **not the
maintainer, not in Los Angeles, not on a US keyboard, and not an English
reader** — without making the maintainer's machine change behaviour by one
byte, and without loading a fresh clone with machinery it does not use.

The value proposition committed to for v1 is narrow on purpose:

> A German or Japanese user who installs from the ISO, adopts the flake, and
> rebuilds should get their timezone, their locale, their keyboard and a
> console/greeter that is not lying about which keys are where — and should
> have to edit exactly one file to get it, the same file the maintainer
> already edits.

Not a translated desktop. Translation of first-party strings is stages 3-5 and
is explicitly **downstream of, and separable from, the day-one cut** (§10).
The reason is measured, not stylistic: a German user fighting a `us` keymap at
the LUKS prompt is blocked; a German user reading "Next theme" in English is
inconvenienced. The first is a bug, the second is a backlog.

## 2. Scope: four layers, treated separately

They have different owners, different failure modes, and different costs, and
conflating them is how i18n projects stall.

| | layer | what it decides | blocking? | stage |
|---|---|---|---|---|
| **(a)** | system locale | `LANG`/`LC_*`, timezone, xkb layout, console keymap, fonts, input methods, RTL awareness | **yes** | 0-1 |
| **(b)** | first-party strings | greeter, waybar, notifications, Hyprland welcome, the control-center menus, the Rust TUIs | no | 3-4 |
| **(c)** | content | scrollmapper's scripture, boot-intro branding text, README/`docs/` | no | 5 |
| **(d)** | installer flow | what Calamares chose → what the flake does | **yes** | 2 |

### 2.1 Non-goals — what is NOT localized, and why

These are decisions, not omissions. Each one is a thing someone will
eventually propose; the reasoning is recorded here so the answer does not have
to be re-derived.

- **MCP tool names and their descriptions.** `modules/mcp-servers/` is a
  machine-facing surface: the names are an ABI the agent host binds to, and
  the descriptions are prompt material an English-language model reads. A
  translated `dsp_status` is a broken tool; a translated description is a
  degraded one. `.#mcp-self-audit` should grow an assertion that no catalog
  key resolves into that workspace.
- **`oligarchy-ctl` action ids.** The left half of `id|Label`
  (`home/apps/control-center/oligarchy-ctl.sh`) is a public API — `warroom`
  drives it, and so does `modules/hypr-controller/hypr_bridge.py` over UDP
  from the Android companion. The **right** half is the only translatable
  half. §3.4 is the landmine section for this and it is worse than it looks.
- **Log lines and journal output.** Every debugging instruction in `docs/`
  and every gate that greps a journal (`.#p2p-signature-refusal`,
  `modules/guest.nix`'s console redirect, `plugind selftest`) assumes English
  log text. Translating logs breaks the gates and the support path
  simultaneously. Logs are English. Forever.
- **Code comments.** 19% of the Nix and Rust in this tree is whole-line
  comments and they are the primary documentation (CLAUDE.md says so).
  Translating them forks the reasoning.
- **Option names, option descriptions, assertion text.** `nixos-option` and
  `nix eval` output is a debugging surface with the same argument as logs.
- **`nix` itself, systemd, the kernel.** Out of scope; they localize or do
  not on their own.
- **The satire README.** See gap 9.

## 3. Verified facts about the current tree

Measured at `76674a9`, against nixpkgs `e820eb4` (25.11). Everything in this
section is checkable; everything outside it is design.

### 3.1 Locale is decided in six places, and three of them are an unmarked mirror

| where | value today | notes |
|---|---|---|
| `configuration.nix:1187` | `time.timeZone = "America/Los_Angeles"` | |
| `configuration.nix:1188-1201` | `i18n.defaultLocale` + nine `LC_*`, all `en_US.UTF-8` | header comment literally says "(unchanged)" |
| `configuration.nix:606-613` | `services.xserver.xkb = { layout = "us"; variant = ""; options = "caps:escape"; }` | for the IceWM X11 backup session |
| `home/hyprland/default.nix:223-224` | `kb_layout = "us"; kb_options = "caps:escape";` | the Wayland session — the one actually used |
| `console.keyMap` | **never set** → nixpkgs default `"us"` | `config/console.nix:70`, type `either str path` |
| `console.font` | **never set** → kernel built-in 8x16, IBM437 glyphs | see §3.3 |

The comment above the xkb block reads *"Keyboard configuration (matches Wayland
setup)"*. That is a hand-maintained mirror with no gate behind it, in a repo
whose other mirrors (`Manifest::wx_enforced()`/`wxEnforced`,
`NarInfo`/`SIGNED_FIELDS`) are all called out in CLAUDE.md as landmines. Set a
German layout in one and the other silently keeps `us`: the Wayland session is
correct and IceWM — the *recovery* session you reach when Hyprland is broken —
is not. **A third member joins the mirror the moment `console.keyMap` is set**,
which is the LUKS/initrd/TTY keymap, i.e. the one that matters most when things
are on fire.

None of `hosts/{framework13,intel,optimus,builder}/` override any of this; those
directories contain `hardware-configuration.nix` and nothing else. Per-host
divergence today happens in `flake.nix`'s per-host module lists, next to
`custom.platform` (`flake.nix:488`, `:623`, `:640`, `:653`, `:693`).

### 3.2 `i18n.supportedLocales` is the wrong lever on 25.11

Worth stating because it is a natural first move and it is now wrong. In
nixpkgs 25.11 (`nixos/modules/config/i18n.nix`), `i18n.supportedLocales` is
`visible = false` and its default is **derived**:

```nix
default = lib.unique ([ "C.UTF-8/UTF-8" "en_US.UTF-8/UTF-8" ] ++ aggregatedLocales);
# aggregatedLocales = defaultLocale + extraLocaleSettings (minus LANGUAGE) + extraLocales
```

So the absence of `i18n.supportedLocales` from `configuration.nix` is **not a
gap** — the locale set already tracks `defaultLocale`/`extraLocaleSettings`
automatically. The supported lever for "also generate `ja_JP.UTF-8`" is:

```nix
i18n.extraLocales = [ "de_DE.UTF-8/UTF-8" ];   # types.either (listOf str) (enum [ "all" ])
```

Note the shapes differ and mixing them is a silent miss: `extraLocales` entries
carry a `/CHARSET` suffix, `extraLocaleSettings` values must **not**
(`i18n.nix` says so explicitly; per-key charsets go in `i18n.localeCharsets`).

### 3.3 There are no system fonts in this distribution

`fonts.packages` is set **nowhere** in the tree. The only hit is
`modules/ArchibaldOS/modules/desktop.nix:20`, which is a different operating
system (the DSP guest). The distro's fonts come entirely from
`home/packages.nix:7-15` (`jetbrains-mono`, `nerd-fonts.jetbrains-mono`,
`font-awesome`, `noto-fonts`, `noto-fonts-color-emoji`, `inter`) rendered by
`fonts.fontconfig.enable = true` at `home/home.nix:102` — **Home Manager, user
scope**.

Three consequences, all currently invisible because everything is Latin:

1. **No CJK font exists anywhere in the closure.** `noto-fonts` does not
   include `noto-fonts-cjk-sans`. A Japanese or Chinese locale renders tofu in
   kitty, waybar, wofi and every GTK/Qt app.
2. **The greeter has no fonts at all.** `services.greetd` runs `tuigreet` as
   the system user `greeter` (`configuration.nix:797-808`), which has no Home
   Manager profile. Whatever `home/packages.nix` installs is not on its
   fontconfig path.
3. **`tuigreet` is a TTY application** (`useTextGreeter = true`,
   `configuration.nix:801`). It draws on the Linux virtual console, whose font
   is a PSF limited to 256 or 512 glyphs. This is not a fontconfig problem and
   no package fixes it — see gap 3.

### 3.4 The control centre round-trips through the *label*, and one dispatch globs it

`oligarchy-ctl.sh` emits `id|Label` lines. Every front-end then shows column 2
to the user and maps the chosen string back to column 1 by **exact match**:

```sh
# home/apps/control-center/oligarchy-control.sh:32
act_id="$(oligarchy-ctl all-items | awk -F'|' -v l="$act_label" '$2==l{print $1; exit}')"
```

Same pattern at `oligarchy-control.sh:41,48`, `oligarchy-menu.sh:11,23,32`,
`dcf-control.sh:37`. This is *good news*: translating column 2 is safe because
both sides of the round trip come from the same `oligarchy-ctl` invocation in
the same locale. Two conditions make it safe, and both become gate obligations:

- **Labels must stay unique within a category after translation.** `$2==l …
  exit` takes the first match. A German catalog that renders two DSP items as
  "Patchbay" silently fires the wrong action. Nothing today enforces
  uniqueness because English happens to be unique.
- **The literals the front-ends inject themselves are not in the catalog.**
  `'← Back'` (`oligarchy-control.sh:45`, `oligarchy-menu.sh:35`) and
  `$SEARCH_ALL` are prepended locally, and the fzf/wofi prompts
  (`'⌁ category ❯ '`, `"Persona (current: $active)"`) are inline.

And one that is not safe:

```sh
# home/apps/control-center/oligarchy-ctl.sh:235-241  — label-glob dispatch
case "$choice" in
  *Studio*)  run persona-studio ;;
  *Gaming*)  run persona-gaming ;;
  ...
```

`persona_menu` dispatches on a **glob over the translated label**. Translate
the persona names and every branch falls through: the menu appears, the user
picks, and nothing happens, with no error. This must be converted to id-based
dispatch *before* any catalog touches the persona labels, and the conversion is
correct on its own merits today.

### 3.5 The installer does not install this distribution at all

This is the single biggest "mainstream" blocker and its shape is not what it
looks like from the outside. Traced through
`nixpkgs/nixos/modules/installer/cd-dvd/installation-cd-graphical-calamares{,-plasma6}.nix`
and `pkgs/by-name/ca/calamares-nixos-extensions/src/modules/nixos/main.py`:

- The upstream base the ISO layers on sets `i18n.supportedLocales = [ "all" ]`
  and ships `glibcLocales`, so the **live** environment can offer every locale.
  Our ISO block (`flake.nix:748-838`) does not disturb that.
- Calamares' `nixos` module templates a **stock** `configuration.nix` — it has
  string templates for `time.timeZone` (`main.py:87`), `i18n.defaultLocale` +
  the nine `extraLocaleSettings` (`:91-105`), `services.xserver.xkb`
  (`:204-210`) and `console.keyMap` (`:211-213`) — writes it to
  `$ROOT/etc/nixos/configuration.nix` (`:381`, `:786`), and runs
  `nixos-install` (`:797`).
- **No flake is written. `flake.nix` is never mentioned.** The installed
  machine is plain NixOS with the user's locale choices, and Oligarchy is not
  on it.

So the survey framing "the installed system then gets THIS flake's hardcoded
values" is not how it happens — there is no automatic path at all. What
actually happens is worse in one specific way and better in another:

> The ISO produces a correctly-localized *NixOS*. The user then clones this
> repo and runs `sudo nixos-rebuild switch --flake .#nixos --impure` — the
> command the README and `oligarchy-ctl`'s `rebuild_cmd_copy` both hand them —
> and at that instant `/etc/nixos/configuration.nix` stops being read and every
> locale, keyboard and timezone choice they made is replaced by
> `America/Los_Angeles` and `us`. Silently, with a successful build, on the
> reboot after.

Better: nothing needs patching in Calamares. Worse: the loss happens at the
*adoption* step, minutes-to-days after install, when the user has stopped
associating problems with the installer. §6 is the fix.

### 3.6 Voice is pinned to English in three places, two of them options

- `modules/blipply-assistant/src/config.rs:118` — `stt_model: "base.en"`.
  Whisper `.en` weights are English-only; no runtime flag changes that.
- `modules/blipply-assistant/src/config.rs:104` — `voice_model:
  "en_US-lessac-medium"` (Piper).
- `modules/blipply-assistant/src/audio/stt.rs:190` —
  `params.set_language(Some("en"))`, hardcoded. This one survives swapping the
  model and is the only one requiring a code change.
- `modules/demod-voice/config.yaml:1` — `default_language: en`. Already
  option-shaped.

### 3.7 Content that is English by construction

`modules/scrollmapper/package.nix:12-34` offers exactly five translations —
`KJVA`, `KJV`, `CPDV`, `ASV`, `BSB` — and **all five are English**. The module
already has `custom.scrollmapper.translation`, so the *option* generalizes;
`bible_databases` upstream carries non-English texts but none are pinned here,
and each addition is a `fetchurl` + SRI hash (the module's own trust boundary
comment: "a moved tip fails the build instead of shipping substituted
scripture"). Separately, `sample.tsv` and `boot-pool.tsv` are English verse
text read at **eval** time to avoid IFD — a non-English pool is a new file, not
a new option value.

### 3.8 Things that are already halfway there

- `services.boot-intro.titleText`/`bottomText` are plain `str` options
  (`modules/boot-intro/modules/core.nix:407,413`) set from
  `configuration.nix:145-153`. Catalog-shaped already; no code change.
- Waybar's clock `format-alt` is `"󰃭  {:%A, %B %d   󰥔  %H:%M:%S}"`
  (`home/waybar/default.nix:443`). `%A`/`%B` are **already locale-aware**
  through strftime — set `LC_TIME` and the day and month names translate with
  no catalog at all. Only the 24-hour `%H:%M` in `format` is a hard choice.
  Waybar's clock module also accepts a `locale` key, which is the correct
  override when it must differ from `LC_TIME`.
- `home/scripts/default.nix:1` and `home/hyprland/default.nix` already take
  `osConfig ? { }` and read NixOS options with `or` defaults at every hop —
  the exact shape a new locale option must follow. **`home/waybar/default.nix:1`
  does not take `osConfig`** and will need the argument added.

## 4. The option contract (proposed, freeze at stage 0)

### 4.1 `custom.locale.*` — `modules/locale.nix`

Modelled on `modules/platform.nix` (hardware abstraction the hosts differ by)
and `modules/user.nix` (one-file fork point), and defaulting to **exactly
today's values** so that landing stage 0 is a no-op diff on
`nixosConfigurations.nixos`.

```nix
options.custom.locale = {
  language = mkOption {
    type = types.str;
    default = "en-US";
    example = "de-DE";
    description = ''
      UI language as a BCP-47 tag. Drives the glibc locale (via
      custom.locale.glibcLocale), the message catalog selected from
      modules/locale/catalog/, the Whisper/Piper voice models, and the
      default font set. "xx-pseudo" is reserved for the .#i18n-pseudo gate.
    '';
  };

  glibcLocale = mkOption {
    type = types.str;
    default = bcp47ToGlibc config.custom.locale.language;  # "de-DE" -> "de_DE.UTF-8"
    defaultText = literalMD "derived from `custom.locale.language`";
    description = "Escape hatch for tags glibc spells differently (pt-BR, zh-Hans-CN, sr-Latn-RS).";
  };

  region = mkOption {
    type = types.nullOr types.str;
    default = null;                        # null => same as glibcLocale
    example = "de_AT.UTF-8";
    description = ''
      Formats locale: the nine LC_* keys for address/measurement/monetary/
      numeric/paper/telephone/time. Split from `language` because "English UI,
      metric units, ISO dates" is the single most common real configuration
      and forcing it through `language` would mistranslate the UI to get it.
    '';
  };

  timeZone = mkOption { type = types.str; default = "America/Los_Angeles"; };

  keyboard = {
    layout  = mkOption { type = types.str; default = "us"; };   # xkb spelling
    variant = mkOption { type = types.str; default = ""; };
    options = mkOption { type = types.str; default = "caps:escape"; };
    model   = mkOption { type = types.str; default = "pc105"; };
    consoleKeyMap = mkOption {
      type = types.nullOr (types.either types.str types.path);
      default = null;   # null => derive from xkb via console.useXkbConfig
    };
  };

  inputMethod = mkOption {
    type = types.nullOr (types.enum [ "ibus" "fcitx5" "nabi" "uim" "hime" "kime" ]);
    default = null;     # null => auto: fcitx5 for zh/ja/ko, none otherwise
  };

  extraLocales = mkOption {
    type = types.listOf types.str;   # "nl_NL.UTF-8/UTF-8" form, charset suffix required
    default = [ ];
  };

  fonts.autoInstall = mkOption { type = types.bool; default = true; };
  fonts.extraPackages = mkOption { type = types.listOf types.package; default = [ ]; };

  strings.enable = mkOption {
    type = types.bool;
    default = false;    # stage 3 flips this; stages 0-2 ship the module with it off
    description = "Render first-party UI strings from the catalog instead of the English literals.";
  };
  strings.fallbackLanguage = mkOption { type = types.str; default = "en"; };
};
```

Design notes that are decisions, not defaults:

- **`language` is BCP-47, not a glibc locale string.** Three consumers need
  different spellings of the same idea (`de-DE` for the catalog and Piper,
  `de_DE.UTF-8` for glibc, `de` for xkb and Whisper). Picking the glibc
  spelling as canonical would put `_` and `.UTF-8` into catalog filenames and
  Whisper model names. `bcp47ToGlibc` is a pure lookup with a passthrough for
  unknown tags plus an assertion (below).
- **`region` exists because "English UI, local formats" is the common case.**
  A Japanese engineer who reads English docs still wants `ja_JP.UTF-8` dates
  and paper size. Collapsing the two is the mistake every single-knob locale
  design makes.
- **`keyboard.consoleKeyMap = null` derives rather than duplicates.** See
  §4.2.
- **No `custom.locale.enable`.** This module has no off state: every machine
  has a locale. What it must have is a default equal to today's values, which
  is how the ISO stays `mkForce`-free (rule 9) — it adds no unit, no timer, and
  no package beyond fonts that `fonts.autoInstall` already gates to the
  selected language.

### 4.2 How it flows out — one source, five sinks

```nix
config = {
  time.timeZone = mkDefault cfg.timeZone;

  i18n.defaultLocale = mkDefault cfg.glibcLocale;
  i18n.extraLocaleSettings = mkDefault (genAttrs
    [ "LC_ADDRESS" "LC_IDENTIFICATION" "LC_MEASUREMENT" "LC_MONETARY" "LC_NAME"
      "LC_NUMERIC" "LC_PAPER" "LC_TELEPHONE" "LC_TIME" ]
    (_: if cfg.region == null then cfg.glibcLocale else cfg.region));
  # NB: no /CHARSET suffix here — i18n.nix rejects the idea explicitly.
  i18n.extraLocales = cfg.extraLocales;

  services.xserver.xkb = {
    inherit (cfg.keyboard) layout variant options model;
  };

  # Kills the third mirror before it is born: ckbcomp compiles the SAME xkb
  # description into a vconsole keymap, so the TTY and the LUKS prompt cannot
  # disagree with the desktop. Cost: pkgs.ckbcomp (perl) enters the build
  # closure and one small derivation is built per distinct layout.
  console.useXkbConfig = mkDefault (cfg.keyboard.consoleKeyMap == null);
  console.keyMap = mkIf (cfg.keyboard.consoleKeyMap != null)
    (mkDefault cfg.keyboard.consoleKeyMap);

  i18n.inputMethod = mkIf (resolvedIM != null) {
    enable = true;          # 25.11 shape: `enable` + `type`.
    type = resolvedIM;      # `i18n.inputMethod.enabled` is DEPRECATED.
    fcitx5.waylandFrontend = mkIf (resolvedIM == "fcitx5") (mkDefault true);
  };

  fonts.packages = mkIf cfg.fonts.autoInstall (baseFonts ++ scriptFonts ++ cfg.fonts.extraPackages);
  fonts.enableDefaultPackages = mkDefault true;
};
```

`services.xserver.xkb` is set **unconditionally**, not under
`mkIf config.services.xserver.enable`: `console.useXkbConfig`'s implementation
(`config/console.nix:141-152`) reads `config.services.xserver.xkb` regardless of
whether X is enabled, which is exactly what makes this work on a Wayland box.

`scriptFonts` is selected from the language's script, not its region:
`noto-fonts-cjk-sans`/`-serif` for `ja`/`zh`/`ko`,
`noto-fonts` (which already carries Arabic/Hebrew/Devanagari coverage) plus
`noto-fonts-emoji` otherwise. **The base set must include
`noto-fonts-cjk-sans` whenever `language` selects CJK *or* `extraLocales`
mentions one** — a user who reads English but has Japanese filenames is the
case a `language`-only rule misses.

The Home Manager side reads it the way `home/scripts/default.nix:12` already
does, with defaults at every hop so `home/` still evaluates standalone and on a
fresh clone where the module may be absent:

```nix
# home/hyprland/default.nix — replaces the "us" / "caps:escape" literals at :223-224
locale = osConfig.custom.locale or { };
kb = locale.keyboard or { };
...
input = {
  kb_layout  = kb.layout  or "us";
  kb_variant = kb.variant or "";
  kb_options = kb.options or "caps:escape";
  kb_model   = kb.model   or "pc105";
  ...
};
```

### 4.3 Override precedence — the existing channel, unchanged

`configuration.nix:23-41` already imports `~/.config/oligarchy/local.nix` and
`state.nix` from outside the repo under `--impure`. **No new override channel
is introduced.** A user sets:

```nix
# ~/.config/oligarchy/local.nix
{
  custom.locale = {
    language = "de-DE";
    timeZone = "Europe/Berlin";
    keyboard = { layout = "de"; variant = "nodeadkeys"; };
  };
}
```

and everything in §4.2 follows, because every sink is `mkDefault`. Per-host
divergence (a second laptop in another country) goes in `flake.nix`'s host
module list next to `custom.platform`, matching where every other per-host
difference already lives.

This inherits the silent-failure landmine CLAUDE.md already records: **without
`--impure`, `builtins.pathExists` answers `false` rather than erroring**, so a
user who drops `--impure` gets `America/Los_Angeles` back with a successful
build and no warning. Locale makes that failure far more visible than the
existing toggles do (your clock is wrong), which is a small mercy, but the
adoption tool in §6 must print the `--impure` requirement in the file it
writes, as a comment, where the user will read it.

### 4.4 Assertions the module owes

- `bcp47ToGlibc` returning a locale glibc cannot generate → assertion naming
  the tag and pointing at `custom.locale.glibcLocale`. Silent failure mode
  otherwise: glibc falls back to `C`, sort order and month names change, and
  nothing logs.
- `inputMethod != null` while `fonts.autoInstall = false` and no CJK font in
  `fonts.packages` → **warning**, not assertion (a user may have fonts from
  elsewhere).
- `strings.enable = true` with `language` having no catalog → assertion listing
  the available catalogs. Falling back silently to English is the one case
  where fallback is wrong, because the user asked for a language by name.
- `language = "xx-pseudo"` outside a gate build → warning that this is a test
  locale.

## 5. String catalogs (layer b)

### 5.1 One file, three consumers — and that is the whole argument

The same string appears in Nix (`services.boot-intro.titleText`), in bash
(`oligarchy-ctl`'s menu, `notify-send` bodies) and in Rust (`warroom`,
`greeting`). Any design with a per-language *mechanism* also gets a
per-language *file format*, and then "translate the greeter" means editing
three files and keeping their key sets in sync by hand. So:

**The catalog is `modules/locale/catalog/<lang>.json`, flat, dotted keys,
string values, and all three consumers read that exact file.** Nix reads it
with `builtins.fromJSON (builtins.readFile …)` — no IFD, the same trick
`modules/scrollmapper/module.nix` uses to read `sample.tsv` without forcing a
package build at eval time.

```json
{
  "_meta": { "language": "de-DE", "fallback": "en", "coverage": 0.85 },
  "greeter.title": "OLIGARCHY // Die Kriegsmaschine",
  "boot.title": "Oligarchie wird gestartet",
  "hypr.welcome.title": "Willkommen bei Oligarchy",
  "hypr.welcome.body": "Super+Return: Terminal\nSuper+D: Kontrollzentrum\n…",
  "ctl.cat.dsp": "DSP & Audio",
  "ctl.item.theme-next": "Nächstes Thema",
  "warroom.pane.perimeter": "Perimeter",
  "script.screenshot.saved": "Gespeichert unter {path}"
}
```

Rules, locked at stage 0:

- **Keys are namespaced by surface, and for `oligarchy-ctl` the key *is* the
  action id**: `ctl.item.<id>`, `ctl.cat.<id>`. That makes §3.4's dispatch
  problem structurally visible — a label with no id has no key.
- **Interpolation is `{name}`, never positional.** Word order differs; `{0}
  {1}` is a bug generator. The pseudo-locale generator must preserve
  `{…}` spans verbatim (§5.5).
- **No key is ever rendered.** A miss falls back to `fallbackLanguage`, then to
  `en`; if `en` misses too it is a **build failure**, not a runtime one — the
  `en` catalog is the schema.
- **`_meta.coverage`** is the declared floor for `.#catalog-drift` (§8).

### 5.2 Nix

`modules/locale/lib.nix` exposes `t` and `tf`:

```nix
{ lib, language, fallback ? "en" }:
let
  load = l: let f = ./catalog + "/${l}.json";
            in if builtins.pathExists f then builtins.fromJSON (builtins.readFile f) else { };
  chain = [ (load language) (load (head (splitString "-" language))) (load fallback) ];
in {
  t  = key: (findFirst (c: c ? ${key}) (throw "i18n: no catalog defines '${key}'") chain).${key};
  tf = key: args: replaceStrings (map (k: "{${k}}") (attrNames args)) (attrValues args) (t key);
}
```

`throw` rather than a default: a missing key in `en` must fail the build at the
call site that named it, which is the only place with enough context to fix it.

### 5.3 Bash — generated, not sourced from `$HOME`

Two candidates were considered and one is rejected on a security ground, not a
convenience one.

- ~~Source `~/.config/oligarchy/i18n/<lang>.sh` at runtime.~~ **Rejected.**
  `oligarchy-ctl` is reachable from `hypr_bridge.py` over UDP from a phone on
  the LAN; a sourced shell file in a user-writable path is arbitrary code
  execution in that process, and the repo's whole posture (§"Nobody goes in
  `nix.settings.trusted-users`", `strict-egress`) is against exactly this
  shape. It also breaks rollback: the catalog would not be part of the
  generation.
- **Chosen: a Nix-generated, read-only, store-resident catalog**, sourced by
  absolute store path:

```nix
# modules/locale/msg.nix -> a file of `msg_<sanitized_key>="…"` assignments
i18nCatalog = pkgs.writeText "oligarchy-i18n-${language}.sh"
  (concatMapStringsSep "\n" (k: "msg_${sanitizeKey k}=${escapeShellArg (t k)}") keys);
```

and in the scripts, a five-line helper injected at the top by the same
generator:

```sh
. @i18nCatalog@                       # store path, substituted at build time
msg() { local v="msg_${1//[.-]/_}"; printf '%s' "${!v-$1}"; }
```

Concrete and deliberate: the fallback `${!v-$1}` prints the **key**, which
contradicts §5.1's "no key is ever rendered" — that is on purpose for bash
only, because a bash-level miss cannot fail a build, and a visible
`ctl.item.theme-next` on screen is the loudest possible bug report. The
`.#i18n-pseudo` gate greps for exactly that shape.

### 5.4 Rust — a hand-rolled `t!()` over the shared JSON

Evaluated:

| | `rust-i18n` | `fluent` / `fluent-rs` | hand-rolled `t!()` |
|---|---|---|---|
| catalog format | its own YAML/JSON tree | FTL (its own DSL) | **the shared JSON** |
| plural/gender | basic | excellent (CLDR) | none |
| new deps per crate | proc-macro + serde_yaml | fluent-bundle + intl_pluralrules + unic-langid | none beyond `serde_json`, already present |
| shared with Nix/bash | no | no | **yes** |

**Chosen: hand-rolled**, ~60 lines per crate, because the deciding factor is
not features but §5.1: the catalog has to be *one file* that Nix and bash also
read, and neither library will read the other's format. Fluent's plural and
gender handling is genuinely better and the TUIs have almost no interpolation
to spend it on — `warroom`'s 16 literals, `greeting`'s 9, `dsp-ctl`'s 5,
`oligarchy-forge`'s 3. Revisit if and only if a translator files a bug that
Fluent would have prevented (gap 8).

The crates are five separate sub-flakes and must not gain a shared workspace
member. The catalog reaches them through the environment instead:

```rust
// build-time, no runtime file I/O, no path in the binary
const CATALOG: &str = include_str!(concat!(env!("OLIGARCHY_I18N_CATALOG_DIR"), "/en.json"));
```

with each sub-flake's derivation setting
`OLIGARCHY_I18N_CATALOG_DIR = ${../locale/catalog}`. English is compiled in as
the guaranteed fallback; the *active* language's JSON is read at startup from
`$OLIGARCHY_I18N_CATALOG` (a store path set by the NixOS/HM module), so
switching language is a rebuild of the module, not of five Rust crates.

**TUI width is a Rust-specific hazard.** `ratatui` lays out in columns, and
German runs 30-40% longer than English while CJK is half the characters at
*double* the column width. Rules: never `Constraint::Length` a pane by an
English string's `.len()`; measure with `unicode-width` (`UnicodeWidthStr`),
not `str::len()` or `chars().count()`; and give every label-bearing constraint
a `Constraint::Min`. `warroom`'s one-thread-per-collector design is unaffected
— this is purely `crates/warroom-tui/src/ui/`.

### 5.5 The pseudo-locale is the gate, not a nicety

`xx-pseudo` is **generated**, never authored: a pure Nix function over the `en`
catalog that, for each value,

1. preserves `{placeholder}` spans and anything matching `[A-Z_]{3,}` (unit
   names, env vars) verbatim,
2. expands the remaining text by ~40% by doubling vowels (German/Finnish
   headroom) — `Next theme` → `Neext theeme`,
3. wraps the whole value in `⟦ … ⟧`.

This buys three things a real translation cannot buy before a translator
exists: it finds **every string that never went through the catalog** (it is
not bracketed), it finds **every layout that assumes English width** (it
overflows), and it finds **non-BMP/wide-glyph rendering holes** (the brackets
themselves). It is also the only realistic way to keep stages 3-4 honest
between now and the day someone volunteers a `de-DE.json`.

## 6. Installer round-trip (layer d)

Two candidates.

**(A) Make Calamares write a flake.** Patch or fork
`calamares-nixos-extensions`'s `main.py` so `$ROOT/etc/nixos/` gets a
`flake.nix` pointing at this repo with the user's locale baked in.
**Rejected.** It carries a patch against upstream Python forever; it makes the
Oligarchy ISO unable to install plain NixOS, which is a capability it has today
and a reasonable thing to want from a rescue image; and the ISO already
force-disables thirteen production services precisely to stay a *generic*
installer that happens to be ours.

**(B) `oligarchy-adopt` — a first-boot adoption tool. CHOSEN.** A small script
in the shape of `oligarchy-hw-detect` (`flake.nix:436`, installed onto the ISO at `:835` and
already `nix run .#`-able), run once on the installed system, before or at the
first `nixos-rebuild switch --flake`:

```
$ oligarchy-adopt
  reading  /etc/locale.conf        LANG=de_DE.UTF-8  (+9 LC_*)
  reading  /etc/vconsole.conf      KEYMAP=de-latin1-nodeadkeys
  reading  /etc/localtime       -> ../usr/share/zoneinfo/Europe/Berlin
  reading  /etc/nixos/configuration.nix   services.xserver.xkb.layout = "de"
  writing  ~/.config/oligarchy/local.nix

  custom.locale = {
    language = "de-DE";
    timeZone = "Europe/Berlin";
    keyboard = { layout = "de"; variant = "nodeadkeys"; };
  };

  Review that file, then:  sudo nixos-rebuild switch --flake .#nixos --impure
                                                                    ^^^^^^^^
  --impure is REQUIRED. Without it this file is silently ignored and you
  get America/Los_Angeles back with a successful build.
```

Why (B) is right beyond "less patching":

- It reuses the override channel that **already exists and that the
  maintainer's own machine uses** (`~/.config/oligarchy/local.nix`), so there
  is one mechanism, not two, and it is the one that is already exercised daily.
- It works for a user who installed NixOS by hand, from a minimal ISO, or from
  a different distro's installer — all of which write `/etc/locale.conf`,
  `/etc/vconsole.conf` and `/etc/localtime` identically, because systemd does.
- It is **inspectable and idempotent**: it writes a file the user reads before
  switching, merges into an existing `local.nix` rather than clobbering it
  (which is why it must **not** write `state.nix` — CLAUDE.md records that the
  control centre wholesale-overwrites that file).
- It is testable without KVM: feed it fixture `locale.conf`/`vconsole.conf`/
  zone symlinks in a `runCommand` and diff the emitted Nix (§8,
  `.#locale-adopt-fixtures`).

Half-measure that ships with it, for near-zero cost: `oligarchy-hw-detect`
(`flake.nix:436-449`, which already sniffs the chassis and *suggests the
matching `nixosConfigurations.*` target*) grows two lines printing the current
`localectl` state and the `oligarchy-adopt` command. That puts the warning in
front of the user **on the ISO**, before they have made the choice they are
about to lose.

## 7. Staging

Six stages. File ownership is disjoint per stage so stages 3 and 4 can be
fanned out to parallel agents (stage 4 is itself four independent sub-streams,
one per Rust sub-flake), and **stage 0 is the frozen contract** everything else
compiles against.

| stage | status | delivers | owns (files) | gate |
|---|---|---|---|---|
| **0** | **landed** 2026-09-21 (`feat/locale-day-one`) | frozen contract | `modules/locale.nix`, `modules/locale/lib.nix`, `flake.nix` (commonModules + gate outputs) | `.#locale-contract` |
| **1** | **landed** 2026-09-21 (`feat/locale-day-one`) | system layer works | `modules/locale.nix` (config block), `configuration.nix` (the hardcoded xkb + i18n/time sites), `home/hyprland/default.nix`, `home/waybar/default.nix` (`osConfig` arg, clock) | `.#locale-contract` |
| **2** | **landed** 2026-09-21 (`feat/locale-day-one`) | installer round-trip | `modules/locale/adopt.nix`, `modules/locale/oligarchy-adopt.sh`, `modules/locale/tests/fixtures/`, `flake.nix` ISO block + hw-detect hint | `.#locale-adopt-fixtures`, later `.#test-iso-locale-roundtrip` |
| **3** | not started | Nix + bash strings | `modules/locale/catalog/{en.json,_schema.md}`, `modules/locale/msg.nix`, `home/apps/control-center/*.sh`, `home/scripts/*`, `home/hyprland/default.nix` (welcomeScript), `configuration.nix` (greetd greeting, boot-intro text) | `.#catalog-drift`, `.#i18n-pseudo` |
| **4** | not started | Rust strings (4 parallel sub-streams) | `modules/warroom/crates/warroom-tui/`, `modules/greeting/src/`, `modules/dsp-ctl/`, `modules/oligarchy-forge/` | `.#i18n-pseudo` extended |
| **5** | not started | content + voice | `modules/blipply-assistant/src/{config.rs,audio/stt.rs}`, `modules/demod-voice/config.yaml`, `modules/scrollmapper/` (docs only), `docs/README.<lang>.md` policy | `.#locale-voice-contract` |

**The catalog half of stage 0 moved to stage 3.** `modules/locale/catalog/en.json`,
`_schema.md` and `.#catalog-drift` were listed as stage-0 deliverables because
the key set is what stages 3-5 compile against — but the day-one cut (§10)
ships no strings at all, so a frozen catalog with no consumer would have been
an unexercised file and a gate guarding nothing. `custom.locale.strings.*` is
declared (so the option names stay frozen and stage 3 changes no signature)
and **inert**: nothing reads it yet.

### Stage 0 — the frozen contract — **landed 2026-09-21** (`feat/locale-day-one`)

Lands the option module **declaring nothing in `config`**, the `en` catalog
with every key that stages 3-5 will fill, the `_schema.md`, and the two pure
eval gates. Deliberately a no-op on every host: `nix build
.#nixosConfigurations.nixos.config.system.build.toplevel` must produce the same
store path before and after. That is the point — it is the thing four parallel
streams get to assume.

**Ordering constraint, inherited from `flake.nix`'s own comment ("order
matters — option *declarations* must precede modules that *set* them"):**
`./modules/locale.nix` goes into `commonModules` next to `./modules/platform.nix`
and `./modules/user.nix`, **before** `./configuration.nix`.

**As landed:** every option in §4.1 is declared —
`language`, `glibcLocale`, `region`, `timeZone`,
`keyboard.{layout,variant,options,model,consoleKeyMap}`, `inputMethod`,
`extraLocales`, `fonts.{autoInstall,extraPackages}` and
`strings.{enable,fallbackLanguage}` — with `modules/locale/lib.nix` carrying
`bcp47ToGlibc` and the script/font tables. Two departures from the paragraph
above, both deliberate:
`strings.*` is declared but **inert** (its consumers are stage 3, and the
catalog moved there with them), and stages 0 and 1 landed in the same branch,
so the module shipped with its `config` block rather than options alone —
there was no window in which a downstream stream could have compiled against
an options-only version.

### Stage 1 — the system layer — **landed 2026-09-21** (`feat/locale-day-one`)

Moves the six hardcoded sites (§3.1) behind the contract and kills the xkb
mirror by derivation. The one behaviour change on the maintainer's machine is
`console.useXkbConfig = true`, which makes the TTY keymap `caps:escape`-aware
for the first time; that is a fix, and it is the only diff the gate should
show.

`home/waybar/default.nix` gains `osConfig ? { }` and:

```nix
clock = {
  format = if use24h then "󰥔  {:%H:%M}" else "󰥔  {:%I:%M %p}";
  locale = locale.glibcLocale or "";   # waybar's own clock `locale` key
  ...
};
```

`use24h` derives from `region`/`glibcLocale` (a short table: `en-US`, `en-PH`,
`en-CA` 12-hour, everything else 24), overridable. `format-alt`'s `%A, %B %d`
needs no change (§3.8).

### Stage 2 — installer round-trip — **landed 2026-09-21** (`feat/locale-day-one`)

`oligarchy-adopt` plus the `oligarchy-hw-detect` hint. Independent of stages
3-5 and the second half of the day-one cut (§10).

**As landed:** `modules/locale/adopt.nix` is a `pkgs.writeShellApplication`
reached from `flake.nix` by `pkgs.callPackage`, exposed three ways — `nix run
.#oligarchy-adopt`, `environment.systemPackages` on the ISO beside
`oligarchy-hw-detect`, and the `nativeBuildInputs` of
`.#locale-adopt-fixtures`. `oligarchy-hw-detect` now prints the machine's
`localectl status` (guarded on `command -v`) and the
`oligarchy-adopt` → `nixos-rebuild switch --flake .#nixos --impure` sequence,
with the `--impure` warning spelled out, **on the ISO** — before the user makes
the choice they are about to lose.

### Stage 3 — Nix and bash strings

**Must land `persona_menu`'s id-based dispatch first** (§3.4), as its own
commit, before any catalog touches persona labels. Then: `ctl.item.<id>` /
`ctl.cat.<id>` keys for all ~97 labels, the `'← Back'`/`$SEARCH_ALL`/prompt
literals, the 22 `notify-send` call sites across `home/scripts/`, the Hyprland
welcome body (`home/hyprland/default.nix:65-73` — note it is already a
`printf`-built multi-line string precisely because Hyprland's parser is
line-based, so the catalog value keeps its `\n`s), `tuigreet --greeting`
(`configuration.nix:806`), and `services.boot-intro.{titleText,bottomText}`
(`configuration.nix:145-153`).

### Stage 4 — Rust strings

Four sub-streams sharing only `modules/locale/catalog/en.json`, which stage 0
froze. Each adds the ~60-line `t!()` and the `OLIGARCHY_I18N_CATALOG_DIR` env
var to its own `flake.nix`. `warroom-tui` additionally owes the `unicode-width`
layout audit (§5.4).

### Stage 5 — content and voice

`blipply` derives `stt_model` and `voice_model` from `custom.locale.language`
(and `stt.rs:190` from the same, instead of `Some("en")`); `demod-voice`'s
`default_language` likewise. Scrollmapper gets a documentation change only —
see gap 6. `docs/` policy per gap 9.

## 8. Gates

All `packages.*`, never `checks` — `checks.x86_64-linux` holds only the system
toplevel so a runner without `/dev/kvm` can still run `nix flake check`, and
folding a VM test in silently takes that away. Four of the five below need no
KVM at all.

```bash
nix build .#locale-contract          # pure eval, 5 hosts x 5 languages
nix build .#catalog-drift            # pure eval, key-set divergence
nix build .#locale-adopt-fixtures    # runCommand, no KVM
nix build .#i18n-pseudo              # builds the system under xx-pseudo, greps artifacts
nix build .#test-iso-locale-roundtrip # runNixOSTest, needs KVM
nix build .#locale-voice-contract    # pure eval
```

### `.#locale-contract` — pure eval, no KVM, no closure — **landed 2026-09-21**

Modelled on `.#session-survives-switch` (`flake.nix:1202-1260`), which is this
repo's worked example of "evaluate the real system config, emit JSON, assert
with jq". For each of the five `nixosConfigurations` × each of
`{ en-US, de-DE, ja-JP, ar-SA, xx-pseudo }`:

```nix
cfg = (self.nixosConfigurations.${host}.extendModules {
  modules = [{ custom.locale.language = lang; custom.locale.timeZone = tz; }];
}).config;
```

and assert, per combination:

1. `config.assertions` has no failing entry (forced explicitly — nothing else
   in a pure eval forces them, and a gate that never evaluated an assertion is
   a gate that inspected nothing);
2. `i18n.defaultLocale` is a locale glibc can generate, and appears in the
   derived `i18n.supportedLocales`;
3. `services.xserver.xkb.layout` **equals** the layout in the rendered
   Hyprland config text (`home-manager.users.<user>.wayland.windowManager.hyprland`
   → the generated `hyprland.conf`), and equals what `console.keyMap`/
   `console.useXkbConfig` resolves from — **the mirror assertion**, and the
   single most valuable line in this gate;
4. a CJK language pulls a CJK font into `fonts.packages`, and an RTL language
   pulls a font with Arabic coverage;
5. `time.timeZone` names a real zone in `tzdata`.

Anti-vacuity, per `mcp_self_audit`'s two rules: the gate asserts a **minimum
combination count** (25) and fails if any combination was skipped rather than
inspected. A skipped combination is reported, never omitted.

**As landed** (`flake.nix`, `packages.x86_64-linux.locale-contract`), with the
three places the implementation differs from the sketch above and why:

- **The mirror compares the Home Manager option value, not the rendered
  `hyprland.conf` text** — `home-manager.users.<user>.wayland.windowManager.hyprland.settings.input.kb_layout`
  against `services.xserver.xkb.layout`. One hop upstream of the text, which is
  where the mirror can actually diverge; reading the generated file back would
  cost a build and buy a regex. The `console` half is asserted as
  `console.useXkbConfig == true` (every combination leaves
  `keyboard.consoleKeyMap` null, so a false here means the TTY and the LUKS
  prompt stopped deriving from the same xkb description). Read with `or null`
  at every hop and **counted**: if no combination could check the mirror, the
  gate fails rather than passing having compared nothing.
- **The timezone is checked in the builder, not at eval.** `builtins.pathExists
  "${pkgs.tzdata}/share/zoneinfo/<tz>"` is a trap in a pure eval: `tzdata` need
  not be realized, and `pathExists` on an unbuilt store path answers `false` —
  a gate that fails for a reason that has nothing to do with the timezone. So
  `tzdata` is a build input and the test is `[ -e … ]` in the script, plus an
  equality check that `time.timeZone` is what `custom.locale.timeZone` asked
  for.
- **A combination that cannot be evaluated becomes a reported SKIP**, via
  `builtins.tryEval` over a `deepSeq` of the row, and a SKIP counts against the
  required 25 and so fails the gate. Without it a single bad host/language pair
  aborts the whole eval with a trace that never names which pair died.

Warnings are collected and printed per combination but never fail the gate —
§4.4 requires a warning (not an assertion) for `xx-pseudo` and for an input
method without fonts, and a gate that failed on those would make the contract
untestable at exactly the point it was designed to be visible.

### `.#catalog-drift` — the maintenance answer

Pure eval over `modules/locale/catalog/*.json`:

- any key in `<lang>.json` **not** in `en.json` → **FAIL** (stale key: the
  English string was renamed and the translation was not);
- coverage (`|keys(<lang>) ∩ keys(en)| / |keys(en)|`) below that catalog's own
  `_meta.coverage` → **FAIL**; above it → the gate prints the new figure and
  tells you to raise the floor (a ratchet, so coverage cannot silently rot);
- `{placeholder}` sets differing between `en` and `<lang>` for the same key →
  **FAIL** (a translator who dropped `{path}` produces a message that lies);
- **label uniqueness**: within each `ctl.cat.*` group, no two `ctl.item.*`
  values may be equal in any language → **FAIL** (§3.4's `$2==l … exit`).

This is the answer to "who updates the catalogs when strings change": nobody
has to remember, because renaming an English key turns every translation red
with the key name in the failure.

### `.#i18n-pseudo` — finds unlocalized strings with no translator

Builds the system with `custom.locale.language = "xx-pseudo"` and
`strings.enable = true`, then greps the **generated artifacts** — not the
sources — for English:

- the rendered `greetd` `ExecStart` (the `--greeting` argument),
- the generated `waybar` `config`/`style` JSON,
- every `home.file` under `.config/hypr/scripts/`,
- `boot-intro`'s `titleFile`/`bottomFile` (`modules/boot-intro/modules/core.nix:86-87`),
- the `oligarchy-ctl` store path.

Rule: any run of ≥4 ASCII letters **outside** a `⟦…⟧` span, and not on the
allowlist (action ids, unit names, env vars, CLI flags, `%`-format specifiers),
is an unlocalized literal → FAIL, printed with file and line. Plus the bash
key-leak check: any `msg_[a-z_]+` or bare dotted key (`ctl.item.theme-next`) in
output text → FAIL. Plus anti-vacuity: the gate must find at least N bracketed
strings, or it inspected nothing and FAILS.

### `.#locale-adopt-fixtures` — no KVM — **landed 2026-09-21**

`runCommand` over `modules/locale/tests/fixtures/<case>/` — each a fake
`/etc` with `locale.conf`, `vconsole.conf`, a `localtime` symlink and a stock
Calamares `configuration.nix`. Runs `oligarchy-adopt --root <fixture> --stdout`
and diffs against the expected Nix. Cases: German, Japanese, Arabic, a
`LANG`-only file with no `LC_*`, a missing `vconsole.conf`, an existing
`local.nix` with unrelated content (merge, do not clobber), and one where
`localtime` is a copy rather than a symlink.

**As landed:** a `pkgs.runCommand` over `modules/locale/tests/fixtures/*/`. A
case carrying `existing-local.nix` is the merge case and is driven differently
— the file is copied somewhere writable, `oligarchy-adopt --root <case> --out
<copy>` is run, and the **resulting file** is diffed against `expected.nix`;
every other case diffs `--stdout`. `HOME` is set to the build directory so no
code path can reach a real `~/.config`. Zero fixture directories is a FAIL, and
so is a directory with no `expected.nix` beside it.

### `.#test-iso-locale-roundtrip` — `runNixOSTest`, KVM, later

Boots a VM, plants the fixture `/etc` a Calamares install leaves behind, runs
`oligarchy-adopt`, and asserts the emitted `local.nix` evaluates and yields the
expected `custom.locale.*`. Exposed as `packages.test-iso-locale-roundtrip`
alongside the existing five in `tests/default.nix`, and **not** added to
`checks` for the reason above.

### `.#locale-voice-contract` — pure eval

Asserts the Whisper model name and Piper voice in blipply's default config are
**functions of** `custom.locale.language`, not literals: extend with three
languages and assert three distinct model names, and that `en-US` still yields
exactly `base.en` / `en_US-lessac-medium` so the maintainer's machine is
unchanged.

---

## 9. Known gaps and risks

Numbered so they can be cited. Each names the stage that will hit it.

**1. RTL is not solved by a locale, and two components cannot be fixed here.**
*(stages 1, 3)* GTK3 (waybar, wofi) picks text direction from gettext's
translation of the magic `default:LTR` string — so waybar's *text* will flip
with a real translated GTK stack, but its **bar layout will not**:
`modules-left`/`modules-right` (`home/waybar/default.nix:8-30`) are literal
positions, and an Arabic user wants them mirrored. That is a catalog-adjacent
config change, not a font or locale change, and stage 3 owes an
`rtl`-conditional swap. **kitty implements no BiDi at all** (upstream position,
not a packaging gap): Arabic and Hebrew render in logical order, unshaped.
Hyprland itself has no notion of direction. Honest posture: Arabic/Hebrew is a
supported *system* locale (layer a) and an **unsupported UI language** (layer
b) until someone with the language files bugs. Say so in the module
description; do not ship an `ar` catalog that implies otherwise.

**2. CJK in kitty works; CJK in the greeter does not.** *(stage 1)* Once
`noto-fonts-cjk-sans` is in `fonts.packages`, kitty, waybar and wofi render
Japanese correctly — kitty falls back per-glyph through fontconfig, and the
`JetBrainsMono Nerd Font` at `home/terminal/kitty.nix:43` has no CJK coverage,
so the fallback is load-bearing and must be verified, not assumed. Column
alignment in TUIs is then the §5.4 problem, not a font problem.

**3. `tuigreet` cannot display CJK or Arabic, and no package fixes it.**
*(stage 3)* It is a TTY application under `useTextGreeter = true`
(`configuration.nix:801`), drawing on the Linux virtual console. The VT font is
a PSF with a **256-glyph (or 512 with a reduced colour attribute) hard limit**
and no shaping engine — there is no Unicode console font, and `console.font`
cannot make one. Practically: Latin-1, Latin Extended-A, Greek and Cyrillic are
reachable with the right `console.font` (`terminus` variants,
`LatArCyrHeb-16`); CJK and Arabic are not, at all. Two honest options, and
stage 3 must pick one explicitly rather than let it fail silently:
(a) `custom.locale.strings.greeterLanguage`, defaulting to
`fallbackLanguage` whenever the selected language's script is not
VT-representable — the greeter stays English, everything else translates; or
(b) move the greeter to a graphical one (`regreet` under cage, or SDDM) for
those languages, which is a real change to the tty1 ownership story that
`.#session-survives-switch` guards and must not be done casually. **(a) is the
recommendation**; (b) is a separate project.

**4. `console.useXkbConfig` adds `ckbcomp` to the build closure.** *(stage 1)*
Small (perl + a short derivation per layout) but real on a machine where
`nix build` latency is already a recorded annoyance. The alternative — a
hand-written xkb→kbd keymap table — trades a build cost for a fourth mirror,
which is exactly the thing §3.1 exists to stop. Keep ckbcomp; if it ever hurts,
`custom.locale.keyboard.consoleKeyMap` is the escape hatch and the contract
already has it.

**5. Nothing verifies that a *layout* is right, only that it is consistent.**
*(gate design)* `.#locale-contract` asserts the three keyboard sites agree. No
gate can assert `de-latin1-nodeadkeys` is what a German user wants. That
judgement stays with whoever files the bug.

**6. Scrollmapper's default is Orthodox-canon English scripture and should
stay.** *(stage 5)* `custom.scrollmapper.*` is **opt-in and off by default**;
its canon filter is Eastern Orthodox and its text is KJVA, and its own README
already says the filter is Orthodox while the text is not the Orthodox Study
Bible. All five pinned translations are English (§3.7). Recommendation: **do
not** try to make it locale-aware. Add non-English texts as new pinned
`sources` entries *when someone asks for one by name*, with the SRI hash the
module's trust boundary requires, and leave `custom.scrollmapper.translation`
as the knob it already is. A `custom.locale`-driven auto-selection here would
silently change which scripture a user's machine prints on boot as a side
effect of changing their keyboard, which is the worst kind of surprise this
document could introduce.

**7. Translation maintenance has no volunteers and the design must survive
that.** *(ongoing)* This is one maintainer's machine configuration first; it is
not going to acquire a translation team. That is why `.#catalog-drift` ratchets
coverage instead of demanding 100%, why the fallback chain never renders a key
in Nix or Rust, and why `xx-pseudo` — which needs no human — is the gate that
runs in CI rather than any real translation. A catalog that falls to 40%
coverage should keep the system working in English and keep the gate green at
its declared floor, not block a rebuild.

**8. The hand-rolled `t!()` has no plural or gender handling.** *(stage 4)*
Fine for 130-odd mostly-nominal TUI labels; wrong the first time someone writes
"3 peers connected". Mitigation: forbid embedded counts in catalog values at
review time (`"{n} peers"` is a trap; `"peers"` + a separate numeric column is
not), and treat the first genuine plural requirement as the trigger to
re-evaluate Fluent (§5.4), not as a thing to hack around.

**9. The README is satire and should not be translated.** *(stage 5)*
`README.md` is in-character ("war machine", fake legal decrees) and CLAUDE.md
already designates `docs/architecture.md` as the source of truth with the
README as tone. Satire is the single hardest register to translate and the
least valuable to get right. Recommendation: **leave `README.md` English**, add
a one-line pointer at its top to `docs/`, and create `docs/README.<lang>.md`
— a plain, un-satirical "what this is, how to install it, how to set your
locale" — **only when a translator shows up**, never machine-translated. If
anything gets translated first it is that page, not the README, and not
`architecture.md` (which is maintenance-heavy and read by people who are
already reading Nix).

**10. `--impure` remains a silent trapdoor, and locale makes it louder.**
*(stage 2)* `~/.config/oligarchy/local.nix` is invisible to pure evaluation and
`pathExists` answers `false` rather than erroring (CLAUDE.md records this). A
user who drops `--impure` loses their locale with a green build. `oligarchy-adopt`
writing the warning as a comment into the file it generates is a mitigation,
not a fix. The real fix is out of scope here: a `custom.locale` that could
assert *"the running system's `localectl` disagrees with the declared config"*
would need to read `/etc` at eval time, which is the same impurity. A runtime
oneshot that warns in the journal after a switch is the cheapest honest option
and is not proposed for v1.

**11. This is one person's laptop configuration and the abstractions are new.**
*(all stages)* `custom.platform` and `custom.desktopFeatures` exist because the
same realization already happened twice; `custom.locale` is the third instance
of the same pattern and will be wrong in the same way — some site will need a
knob that is not there. The contract is designed to be *extended* (new
sub-options, `mkDefault` everywhere, an escape hatch next to every derived
value) rather than *correct*, and stage 0 freezing it early is a bet that
extension is cheaper than churn across four parallel streams.

## 10. Day one — the minimal cut — **shipped 2026-09-21** (`feat/locale-day-one`)

The smallest change that makes a German or Japanese user's fresh install stop
fighting them. **Stages 0, 1 and 2 only. No string work at all.** All six
items below are in the tree; the paragraph that follows them is now a
description of the shipped path, not a plan.

1. `modules/locale.nix` with `language`, `region`, `timeZone`, `keyboard.*`,
   `inputMethod`, `extraLocales`, `fonts.*` — every default equal to today's
   value (§4.1).
2. Six hardcoded sites moved behind it, xkb mirror killed by
   `console.useXkbConfig` (§3.1, §4.2).
3. `fonts.packages` exists at the system level for the first time, with CJK
   pulled in by language (§3.3).
4. `i18n.inputMethod.{enable,type}` wired, `fcitx5.waylandFrontend` on (§4.2).
5. `oligarchy-adopt` + the `oligarchy-hw-detect` hint (§6).
6. Gates: `.#locale-contract`, `.#locale-adopt-fixtures`.

After that cut, a German user's path is: install from the ISO as usual → clone
→ `oligarchy-adopt` → read the file it wrote →
`sudo nixos-rebuild switch --flake .#nixos --impure`. Their clock, their
keyboard (desktop, X11 fallback **and** TTY), their date and paper formats and
their fonts are right. The menus are in English. That is a shippable product;
stages 3-5 are an improvement to it, not a prerequisite.

Explicitly **not** in the day-one cut, and why: every catalog, every `t!()`,
the pseudo-locale gate, the persona dispatch fix, and all voice work. None of
them block a non-English user from running the machine, and all of them touch
files that stages 0-2 do not.

---

## 11. Changelog

| date | change |
|---|---|
| 2026-09-21 | **Stages 0, 1 and 2 landed** on `feat/locale-day-one` — the §10 day-one cut. `modules/locale.nix` + `modules/locale/lib.nix` declare and wire the full §4.1 option set (`strings.*` declared but inert); `configuration.nix`, `home/hyprland/` and `home/waybar/` moved onto it; `modules/locale/adopt.nix` + `oligarchy-adopt.sh` + fixtures; `flake.nix` gains `./modules/locale.nix` in `commonModules` (before `configuration.nix`), `packages.oligarchy-adopt`, the tool on the ISO, a `localectl` + `--impure` hint in `oligarchy-hw-detect`, and the gates `.#locale-contract` (5 hosts × 5 languages, 25 combinations, the xkb/Hyprland/console mirror) and `.#locale-adopt-fixtures`. §4.1 names are frozen from here. The catalog half of stage 0 (`catalog/en.json`, `_schema.md`, `.#catalog-drift`) moved to stage 3, where its consumers are. |
| 2026-09-21 | Document created. Nothing landed. §3 measured against `76674a9` / nixpkgs `e820eb4` (25.11); §§1-2, 4-10 are proposal. Three survey corrections recorded in §3.2 (`supportedLocales` is derived on 25.11, `extraLocales` is the lever), §3.1 (`services.xserver.xkb` **does** exist, at `configuration.nix:606-613`, as an unmarked mirror) and §3.5 (the ISO installs stock NixOS with no flake — the locale loss happens at flake adoption, not at install). |

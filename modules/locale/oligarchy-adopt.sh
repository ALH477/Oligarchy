#!/usr/bin/env bash
# oligarchy-adopt — carry an installed machine's locale into Oligarchy.
#
# docs/localization-roadmap.md §3.5 records the actual failure this exists to
# fix: the ISO's Calamares writes a correctly-localized *plain NixOS* into
# /etc/nixos/configuration.nix and never mentions a flake. The moment the user
# runs the command the README hands them —
#   sudo nixos-rebuild switch --flake .#nixos --impure
# — /etc/nixos/configuration.nix stops being read and every locale, keyboard
# and timezone choice they made is silently replaced by this repo's defaults,
# with a successful build, on the reboot after.
#
# §6 option (B): rather than patching Calamares, read what the installer (or
# systemd, or another distro's installer) already wrote under /etc and emit a
# `custom.locale` fragment into the override channel that already exists and
# is already exercised daily — ~/.config/oligarchy/local.nix.
#
# Read-only with respect to the adopted root. The only thing it writes is the
# --out file, and it backs that up first. It never writes state.nix: the
# control centre wholesale-overwrites that file (CLAUDE.md), so anything put
# there would be lost without warning.
set -euo pipefail

# ---------------------------------------------------------------------------
# Module defaults — docs/localization-roadmap.md §4.1. A key whose adopted
# value equals its default is omitted from the fragment, so adopting a machine
# that already matches Oligarchy produces a one-line no-op rather than a wall
# of redundant settings. `language` is the exception: it is always emitted, so
# the file the user opens always shows what was actually detected.
# ---------------------------------------------------------------------------
readonly DEF_LANGUAGE="en-US"
readonly DEF_TIMEZONE="America/Los_Angeles"
readonly DEF_LAYOUT="us"
readonly DEF_VARIANT=""
readonly DEF_OPTIONS="caps:escape"

# The nine formats LC_* keys, in the order NixOS' i18n.extraLocaleSettings
# lists them. LC_TIME leads because it is the one a human notices first and
# the one this tool prefers when they disagree.
readonly LC_FORMAT_KEYS="LC_TIME LC_ADDRESS LC_IDENTIFICATION LC_MEASUREMENT LC_MONETARY LC_NAME LC_NUMERIC LC_PAPER LC_TELEPHONE"

prog=oligarchy-adopt

die() {
  printf '%s: %s\n' "$prog" "$*" >&2
  exit 1
}

# All chatter goes to stderr, unconditionally: --stdout must print the
# fragment and nothing else, because .#locale-adopt-fixtures diffs it
# byte-for-byte against modules/locale/tests/fixtures/<case>/expected.nix.
say() {
  printf '%s\n' "$*" >&2
}

usage() {
  cat <<'EOF'
oligarchy-adopt — read an installed system's locale and emit custom.locale.

Usage:
  oligarchy-adopt [--root DIR] [--stdout] [--out FILE]

  --root DIR    filesystem root to read from (default: /). Reads
                DIR/etc/locale.conf, DIR/etc/vconsole.conf, DIR/etc/localtime,
                DIR/etc/timezone and DIR/etc/nixos/configuration.nix.
  --stdout      print only the custom.locale fragment on stdout and write
                nothing. Chatter still goes to stderr.
  --out FILE    file to merge the fragment into
                (default: $HOME/.config/oligarchy/local.nix). Backed up to
                FILE.bak-adopt before any change.
  -h, --help    this text.

Exit status:
  0  fragment emitted (and, without --stdout, merged into FILE)
  1  nothing could be read under --root, or FILE could not be merged
  2  FILE already sets custom.locale.* in the dotted form; it needs a hand
     edit first. Nothing was written.

After running, review the file and then:
  sudo nixos-rebuild switch --flake .#nixos --impure
--impure is REQUIRED; without it the file is silently ignored.
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
root="/"
to_stdout=0
out=""

while [ "$#" -gt 0 ]; do
  case "$1" in
  --root)
    [ "$#" -ge 2 ] || die "--root needs a directory"
    root="$2"
    shift 2
    ;;
  --root=*)
    root="${1#--root=}"
    shift
    ;;
  --stdout)
    to_stdout=1
    shift
    ;;
  --out)
    [ "$#" -ge 2 ] || die "--out needs a file"
    out="$2"
    to_stdout=0
    shift 2
    ;;
  --out=*)
    out="${1#--out=}"
    to_stdout=0
    shift
    ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    die "unknown argument: $1 (try --help)"
    ;;
  esac
done

[ -n "$root" ] || die "--root must not be empty"
# "/" -> "" so that "$root/etc/locale.conf" renders as "/etc/locale.conf" for
# both the default root and a fixture root, with no doubled slash.
root="${root%/}"

if [ -z "$out" ]; then
  [ -n "${HOME:-}" ] || die "--out not given and HOME is unset"
  out="$HOME/.config/oligarchy/local.nix"
fi

locale_conf="$root/etc/locale.conf"
vconsole_conf="$root/etc/vconsole.conf"
localtime="$root/etc/localtime"
timezone_file="$root/etc/timezone"
nixos_conf="$root/etc/nixos/configuration.nix"

# Nothing to adopt at all is an error, not an empty fragment: a user who
# pointed this at the wrong root should hear about it rather than receive a
# confident `language = "en-US";` describing nothing.
if [ ! -r "$locale_conf" ] && [ ! -r "$nixos_conf" ]; then
  die "nothing to adopt under ${root:-/}: no etc/locale.conf and no etc/nixos/configuration.nix"
fi

# ---------------------------------------------------------------------------
# Readers
# ---------------------------------------------------------------------------

# conf_get FILE KEY — value of a systemd-style KEY=value line, last wins,
# surrounding quotes and trailing whitespace stripped. Commented-out lines do
# not match because the pattern anchors KEY to the start of the line.
conf_get() {
  local file="$1" key="$2"
  [ -r "$file" ] || return 0
  sed -n -e 's/\r$//' -e "s/^[[:space:]]*${key}=[[:space:]]*//p" "$file" |
    tail -n 1 |
    sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'\$//" -e 's/[[:space:]]*$//'
}

# nix_get FILE ATTR — value of a `attr = "…";` line in a stock Calamares
# configuration.nix. ATTR is an extended regex with dots already escaped.
# Deliberately a grep and not an evaluation: this runs on a machine that may
# not have Nix on PATH yet, and the file it reads is a template with known
# shape, not arbitrary Nix.
nix_get() {
  local file="$1" attr="$2"
  [ -r "$file" ] || return 0
  { grep -E "^[[:space:]]*${attr}[[:space:]]*=[[:space:]]*\"" "$file" || true; } |
    tail -n 1 |
    sed -E 's/^[^"]*"([^"]*)".*/\1/'
}

# nix_block_get FILE BLOCK KEY — value of `KEY = "…";` *inside* a nested
# `BLOCK = { … };` attribute set. BLOCK and KEY are plain attribute paths
# ("services.xserver.xkb", "layout"); the dots are escaped here, not by the
# caller, because passing a pre-escaped regex through awk -v turns `\.` into a
# bare dot and silently makes every separator a wildcard.
#
# This exists because the dotted form nix_get reads is NOT what Calamares
# writes. calamares-nixos-extensions' `cfgkeymap` template emits, verbatim:
#
#     # Configure keymap in X11
#     services.xserver.xkb = {
#       layout = "…";
#       variant = "…";
#     };
#
# so a grep for `services.xserver.xkb.layout = ` finds nothing on a real
# Calamares install and the user's layout is invisible — the exact silent
# fallback-to-defaults this tool exists to prevent. Both shapes are read:
# the block first (what the installer writes), the dotted form second (what a
# hand-edited or nixos-generate-config-flavoured file may carry).
#
# `time.timeZone`, `i18n.defaultLocale` and `console.keyMap` really are dotted
# in that template, so nix_get stays correct for those. `i18n.extraLocaleSettings`
# is a nested block too, but it is not read: a NixOS system that has a
# configuration.nix also has /etc/locale.conf generated from it, and /etc/* wins
# here anyway, so parsing it would add a second source that can never disagree.
nix_block_get() {
  local file="$1" block="$2" key="$3"
  [ -r "$file" ] || return 0
  awk -v block="$block" -v key="$key" '
    BEGIN {
      gsub(/\./, "\\.", block)
      gsub(/\./, "\\.", key)
      inblock = 0
      val = ""
    }
    !inblock {
      if ($0 ~ ("^[ \t]*" block "[ \t]*=[ \t]*\\{[ \t]*$")) {
        match($0, /^[ \t]*/)
        ind = substr($0, 1, RLENGTH)
        inblock = 1
      }
      next
    }
    {
      # Close on the first line that is exactly the opening line indentation
      # followed by `};` — the shape the template emits.
      if ($0 ~ ("^" ind "\\};[ \t]*$")) {
        inblock = 0
        next
      }
      if ($0 ~ ("^[ \t]*" key "[ \t]*=[ \t]*\"")) {
        line = $0
        sub(/^[^"]*"/, "", line)
        sub(/".*$/, "", line)
        val = line
      }
    }
    END { if (val != "") print val }
  ' "$file"
}

# normalize_locale LOCALE — canonicalise a glibc locale string: fold every
# spelling of UTF-8 (`utf8`, `UTF8`, `utf-8`) onto `.UTF-8` and drop an
# @modifier. Charsets that are not UTF-8 are left exactly as found.
#
# The module's well-formedness assertion requires the `.UTF-8` spelling
# literally, so copying LC_TIME=de_DE.utf8 through verbatim produced a
# fragment that FAILED to evaluate; and comparing an un-normalised LC_* value
# against LANG made LC_TIME=en_US.utf8 vs LANG=en_US.UTF-8 look like a
# disagreement, emitting a spurious region block for a machine that has none.
normalize_locale() {
  local loc="$1" charset="" folded
  case "$loc" in
  *@*) loc="${loc%@*}" ;;
  esac
  case "$loc" in
  *.*)
    charset="${loc##*.}"
    loc="${loc%%.*}"
    ;;
  esac
  if [ -n "$charset" ]; then
    folded="${charset,,}"
    folded="${folded//[-_]/}"
    if [ "$folded" = "utf8" ]; then
      charset="UTF-8"
    fi
    printf '%s.%s' "$loc" "$charset"
  else
    printf '%s' "$loc"
  fi
}

# ---------------------------------------------------------------------------
# Language: glibc locale string -> BCP-47 tag
# ---------------------------------------------------------------------------
lang_note=""
language=""

# glibc_to_bcp47 LOCALE — "de_DE.UTF-8" -> "de-DE", "ja_JP.UTF-8" -> "ja-JP",
# "eo" -> "eo". The charset suffix is dropped because BCP-47 has no place for
# it (custom.locale.glibcLocale is the escape hatch, §4.1) and an @modifier is
# dropped with a note for the same reason.
#
# Sets the globals `language` and `lang_note` rather than printing, because
# `language=$(glibc_to_bcp47 …)` would run the body in a subshell and throw
# `lang_note` away with it — i.e. drop the @modifier comment silently, which
# is the one outcome this branch exists to prevent.
glibc_to_bcp47() {
  local loc="$1" work modifier lang country
  language=""
  case "$loc" in
  C | POSIX | C.UTF-8 | C.utf8 | "")
    # The C locale is not a language choice, it is the absence of one. Emitting
    # `language = "C";` would fail bcp47ToGlibc's assertion (§4.4); the module
    # default is the honest answer.
    language="$DEF_LANGUAGE"
    return 0
    ;;
  esac

  work="$loc"
  modifier=""
  case "$work" in
  *@*)
    modifier="${work##*@}"
    work="${work%@*}"
    ;;
  esac
  work="${work%%.*}"

  lang="${work%%_*}"
  country=""
  case "$work" in
  *_*) country="${work#*_}" ;;
  esac

  if [ -n "$modifier" ]; then
    lang_note="$loc has an @${modifier} modifier, which BCP-47 cannot carry"
  fi

  if [ -n "$country" ]; then
    language="${lang}-${country}"
  else
    language="$lang"
  fi
}

# ---------------------------------------------------------------------------
# Keymap: vconsole KEYMAP -> xkb layout/variant
# ---------------------------------------------------------------------------
xkb_layout=""
xkb_variant=""
xkb_known=0

# map_keymap KEYMAP — sets xkb_layout/xkb_variant and xkb_known. The table is
# deliberately short and conservative: an unknown keymap degrades to
# `consoleKeyMap = "<keymap>"` plus a comment, which is honest, rather than to
# a guessed xkb layout, which would silently rearrange the user's keys.
map_keymap() {
  xkb_layout=""
  xkb_variant=""
  xkb_known=0
  case "$1" in
  us) xkb_layout="us" ;;
  dvorak)
    xkb_layout="us"
    xkb_variant="dvorak"
    ;;
  colemak)
    xkb_layout="us"
    xkb_variant="colemak"
    ;;
  de | de-latin1) xkb_layout="de" ;;
  de-latin1-nodeadkeys)
    xkb_layout="de"
    xkb_variant="nodeadkeys"
    ;;
  fr | fr-latin1) xkb_layout="fr" ;;
  uk | gb) xkb_layout="gb" ;;
  jp106) xkb_layout="jp" ;;
  es) xkb_layout="es" ;;
  it) xkb_layout="it" ;;
  sv-latin1 | se-latin1) xkb_layout="se" ;;
  no-latin1) xkb_layout="no" ;;
  dk-latin1) xkb_layout="dk" ;;
  fi | fi-latin1) xkb_layout="fi" ;;
  pl2) xkb_layout="pl" ;;
  cz-lat2) xkb_layout="cz" ;;
  ru) xkb_layout="ru" ;;
  ar) xkb_layout="ara" ;;
  nl) xkb_layout="nl" ;;
  hu) xkb_layout="hu" ;;
  pt-latin1) xkb_layout="pt" ;;
  br-abnt2)
    xkb_layout="br"
    xkb_variant="abnt2"
    ;;
  *)
    return 0
    ;;
  esac
  xkb_known=1
}

# ---------------------------------------------------------------------------
# Gather
# ---------------------------------------------------------------------------
lang_raw=""
region=""
region_raw=""
region_from=""
timezone=""
tz_undetermined=0
keymap=""
kb_layout=""
kb_variant=""
kb_options=""
console_keymap=""
console_keymap_unknown=""

# -- /etc/locale.conf --------------------------------------------------------
if [ -r "$locale_conf" ]; then
  lang_raw="$(conf_get "$locale_conf" LANG)"
  lc_count="$({ grep -c -E '^[[:space:]]*LC_[A-Z_]+=' "$locale_conf" || true; } | tail -n 1)"
  say "  reading  $locale_conf	LANG=${lang_raw:-<unset>}  (+${lc_count:-0} LC_*)"
fi

# -- /etc/nixos/configuration.nix (secondary; /etc/* wins) -------------------
conf_locale=""
conf_tz=""
conf_keymap=""
conf_xkb_layout=""
conf_xkb_variant=""
conf_xkb_options=""
if [ -r "$nixos_conf" ]; then
  conf_locale="$(nix_get "$nixos_conf" 'i18n\.defaultLocale')"
  conf_tz="$(nix_get "$nixos_conf" 'time\.timeZone')"
  conf_keymap="$(nix_get "$nixos_conf" 'console\.keyMap')"

  # The nested block is what Calamares actually writes, so it is tried first;
  # layout and variant are taken from the *same* source so a block layout can
  # never be paired with a dotted variant from somewhere else in the file.
  conf_xkb_layout="$(nix_block_get "$nixos_conf" 'services.xserver.xkb' 'layout')"
  if [ -n "$conf_xkb_layout" ]; then
    conf_xkb_variant="$(nix_block_get "$nixos_conf" 'services.xserver.xkb' 'variant')"
  else
    conf_xkb_layout="$(nix_get "$nixos_conf" 'services\.xserver\.xkb\.layout')"
    conf_xkb_variant="$(nix_get "$nixos_conf" 'services\.xserver\.xkb\.variant')"
  fi

  # `options` is not in the Calamares template at all, so every source is a
  # hand edit and there is no same-source argument to make: take the first
  # one that answers.
  conf_xkb_options="$(nix_block_get "$nixos_conf" 'services.xserver.xkb' 'options')"
  if [ -z "$conf_xkb_options" ]; then
    conf_xkb_options="$(nix_get "$nixos_conf" 'services\.xserver\.xkb\.options')"
  fi
  if [ -z "$conf_xkb_options" ]; then
    # Pre-24.05 spelling, still what an older Calamares template emits.
    conf_xkb_options="$(nix_get "$nixos_conf" 'services\.xserver\.xkbOptions')"
  fi
  if [ -n "$conf_xkb_layout" ]; then
    say "  reading  $nixos_conf	services.xserver.xkb.layout = \"$conf_xkb_layout\""
  elif [ -n "$conf_locale" ]; then
    say "  reading  $nixos_conf	i18n.defaultLocale = \"$conf_locale\""
  else
    say "  reading  $nixos_conf	(no locale keys found)"
  fi
fi

[ -n "$lang_raw" ] || lang_raw="$conf_locale"
[ -n "$lang_raw" ] || die "could not determine a language: no LANG in $locale_conf and no i18n.defaultLocale in $nixos_conf"

glibc_to_bcp47 "$lang_raw"

# -- region: the formats locale, when it disagrees with LANG -----------------
# §4.1: "English UI, metric units, ISO dates" is the single most common real
# configuration, and it is expressed as LANG=en_US.UTF-8 with LC_TIME and
# friends pointing somewhere else. Collapsing the two into `language` would
# mistranslate the UI to get the date format right.
#
# Both sides of the comparison are normalised first, and the value that is
# emitted is the normalised one. LC_TIME=en_US.utf8 against LANG=en_US.UTF-8
# is the same locale spelled two ways, not a disagreement; and the module's
# well-formedness assertion requires the `.UTF-8` spelling literally, so
# copying `de_DE.utf8` through verbatim produced a fragment that refused to
# evaluate.
lang_norm="$(normalize_locale "$lang_raw")"
if [ -r "$locale_conf" ] && [ -n "$lang_raw" ]; then
  for key in $LC_FORMAT_KEYS; do
    raw="$(conf_get "$locale_conf" "$key")"
    [ -n "$raw" ] || continue
    val="$(normalize_locale "$raw")"
    if [ "$val" != "$lang_norm" ]; then
      region="$val"
      region_raw="$raw"
      region_from="$key"
      break
    fi
  done
fi

# -- timezone ----------------------------------------------------------------
if [ -L "$localtime" ]; then
  link="$(readlink "$localtime")"
  say "  reading  $localtime	-> $link"
  case "$link" in
  *zoneinfo/*) timezone="${link#*zoneinfo/}" ;;
  *) timezone="" ;;
  esac
  if [ -z "$timezone" ]; then
    tz_undetermined=1
  fi
elif [ -e "$localtime" ]; then
  # A regular file is what you get from `cp /usr/share/zoneinfo/... /etc/localtime`
  # and from some container images. There is no zone name left in it. timedatectl
  # would answer, but it reads the *running* system and this tool is defined over
  # --root, so asking it would be a lie under any root but "/".
  if [ -r "$timezone_file" ]; then
    timezone="$(sed -n -e 's/\r$//' -e '1s/[[:space:]]*$//p' "$timezone_file")"
    say "  reading  $localtime	(a copy, not a symlink)"
    say "  reading  $timezone_file	$timezone"
  else
    tz_undetermined=1
    say "  reading  $localtime	(a copy, not a symlink; no $timezone_file either)"
  fi
elif [ -r "$timezone_file" ]; then
  timezone="$(sed -n -e 's/\r$//' -e '1s/[[:space:]]*$//p' "$timezone_file")"
  say "  reading  $timezone_file	$timezone"
fi

# /etc/* wins; configuration.nix only fills a gap it left.
if [ -z "$timezone" ] && [ "$tz_undetermined" -eq 0 ] && [ -n "$conf_tz" ]; then
  timezone="$conf_tz"
fi

# -- keyboard ----------------------------------------------------------------
if [ -r "$vconsole_conf" ]; then
  keymap="$(conf_get "$vconsole_conf" KEYMAP)"
  kb_layout="$(conf_get "$vconsole_conf" XKBLAYOUT)"
  kb_variant="$(conf_get "$vconsole_conf" XKBVARIANT)"
  kb_options="$(conf_get "$vconsole_conf" XKBOPTIONS)"
  say "  reading  $vconsole_conf	KEYMAP=${keymap:-<unset>}"
fi

[ -n "$keymap" ] || keymap="$conf_keymap"

# Precedence, most direct answer first: an explicit xkb layout beats a console
# keymap, because mapping a keymap to a layout is lossy and the table above is
# short. Within the explicit answers /etc/* wins over configuration.nix.
if [ -z "$kb_layout" ]; then
  kb_layout="$conf_xkb_layout"
  [ -n "$kb_variant" ] || kb_variant="$conf_xkb_variant"
fi
if [ -z "$kb_options" ]; then
  kb_options="$conf_xkb_options"
fi

if [ -z "$kb_layout" ] && [ -n "$keymap" ]; then
  map_keymap "$keymap"
  if [ "$xkb_known" -eq 1 ]; then
    kb_layout="$xkb_layout"
    kb_variant="$xkb_variant"
  else
    console_keymap_unknown="$keymap"
    console_keymap="$keymap"
  fi
fi

# ---------------------------------------------------------------------------
# Emit
# ---------------------------------------------------------------------------
emit_fragment() {
  local kb_body=""

  printf '  custom.locale = {\n'

  if [ -n "$lang_note" ]; then
    printf '    # %s.\n' "$lang_note"
    printf '    # Set custom.locale.glibcLocale by hand if you need it back.\n'
  fi
  printf '    language = "%s";\n' "$language"

  if [ -n "$region" ]; then
    printf '    # %s=%s disagrees with LANG=%s: keep the UI\n' \
      "$region_from" "$region" "$lang_norm"
    printf '    # language above, take date/number/paper formats from this one instead.\n'
    if [ "$region_raw" != "$region" ]; then
      printf '    # (%s reads "%s" on that machine; normalised to the spelling\n' \
        "$region_from" "$region_raw"
      printf '    # NixOS'"'"' well-formedness check accepts.)\n'
    fi
    printf '    region = "%s";\n' "$region"
  fi

  if [ "$tz_undetermined" -eq 1 ]; then
    printf '    # timeZone: could not determine (localtime is a copy); set it by hand\n'
  elif [ -n "$timezone" ] && [ "$timezone" != "$DEF_TIMEZONE" ]; then
    printf '    timeZone = "%s";\n' "$timezone"
  fi

  # Build the keyboard body first: a block whose every key equals the module
  # default is not worth printing at all.
  if [ -n "$kb_layout" ] && [ "$kb_layout" != "$DEF_LAYOUT" ]; then
    kb_body="${kb_body}      layout = \"${kb_layout}\";
"
  fi
  if [ -n "$kb_variant" ] && [ "$kb_variant" != "$DEF_VARIANT" ]; then
    kb_body="${kb_body}      variant = \"${kb_variant}\";
"
  fi
  # An absent or empty XKBOPTIONS is "not stated", not "the user wants none":
  # emitting `options = "";` would delete caps:escape on every adopted machine
  # for want of a line the installer never writes.
  if [ -n "$kb_options" ] && [ "$kb_options" != "$DEF_OPTIONS" ]; then
    kb_body="${kb_body}      options = \"${kb_options}\";
"
  fi
  if [ -n "$console_keymap" ]; then
    kb_body="${kb_body}      # No xkb mapping is known for the vconsole keymap \"${console_keymap_unknown}\": it
      # is carried over verbatim and keyboard.layout is left at the module
      # default. Set keyboard.layout/variant by hand for X and Wayland.
      consoleKeyMap = \"${console_keymap}\";
"
  fi

  if [ -n "$kb_body" ]; then
    printf '    keyboard = {\n'
    printf '%s' "$kb_body"
    printf '    };\n'
  fi

  printf '  };\n'
}

fragment="$(emit_fragment)"

if [ "$to_stdout" -eq 1 ]; then
  printf '%s\n' "$fragment"
  say ""
  say "  --impure is REQUIRED when you switch, or this is silently ignored:"
  say "    sudo nixos-rebuild switch --flake .#nixos --impure"
  exit 0
fi

# ---------------------------------------------------------------------------
# Write / merge into --out
# ---------------------------------------------------------------------------
header='# ~/.config/oligarchy/local.nix — seeded by oligarchy-adopt.
#
# configuration.nix imports this file ONLY when nixos-rebuild runs with
# --impure. Without --impure it is SILENTLY IGNORED — builtins.pathExists
# answers false rather than erroring, the build succeeds, and the in-repo
# defaults (America/Los_Angeles, us) come back with no warning at all.
#
#   sudo nixos-rebuild switch --flake .#nixos --impure
#                                             ^^^^^^^^
'

out_dir="$(dirname -- "$out")"
mkdir -p -- "$out_dir"

# ---------------------------------------------------------------------------
# Refuse a file that already sets custom.locale.* in DOTTED form.
#
# The merge below recognises only the block form, `custom.locale = {`. A file
# carrying `custom.locale.language = "de-DE";` therefore looks to it like a
# file with no custom.locale at all, so it appends a second definition and the
# result no longer parses:
#
#   error: attribute 'language' already defined at …/local.nix:4:3
#
# That breaks every later `nixos-rebuild switch --flake .#nixos --impure` —
# i.e. this tool would take the user's machine down while claiming success.
# Rewriting dotted keys into the block automatically is not attempted: that is
# an edit to lines this tool did not write, and the user is one paste away
# from doing it correctly. Refuse, name the lines, change nothing.
#
# The refusal fires on ANY dotted line, including a file that ALSO carries a
# block. That case is not merely un-mergeable, it is already broken in the
# same way the moment the two shapes name one key: replacing the block with a
# fragment that sets `timeZone` next to a surviving
# `custom.locale.timeZone = …;` line is the identical
# "attribute already defined" failure.
#
# Exit status 2 is distinct from die()'s 1 on purpose: "your file needs a
# hand edit" is a different outcome from "I could not read that root", and a
# script wrapping this one should be able to tell them apart.
if [ -e "$out" ]; then
  dotted="$({ grep -n -E '^[[:space:]]*custom\.locale\.' "$out" || true; })"
  if [ -n "$dotted" ]; then
    while IFS= read -r line; do
      printf '%s: %s:%s\n' "$prog" "$out" "$line" >&2
    done <<EOF
$dotted
EOF
    # shellcheck disable=SC2016  # the backticks quote Nix syntax for the
    # reader; nothing here is a command substitution.
    printf '%s: %s\n' "$prog" \
      'local.nix already sets custom.locale.* in dotted form; move those into a `custom.locale = { … };` block or delete them, then rerun' >&2
    exit 2
  fi
fi

tmp="$(mktemp -- "${out}.adopt.XXXXXX")"
# shellcheck disable=SC2064  # $tmp is fixed here; expand it now, not at exit.
trap "rm -f -- '$tmp'" EXIT

if [ ! -e "$out" ]; then
  action="creating"
  {
    printf '%s' "$header"
    printf '{ pkgs, lib, ... }: {\n'
    printf '%s\n' "$fragment"
    printf '}\n'
  } >"$tmp"
else
  action="updating"
  cp -p -- "$out" "$out.bak-adopt"

  start="$({ grep -n -E '^[[:space:]]*custom\.locale[[:space:]]*=[[:space:]]*\{' "$out" || true; } | head -n 1 | cut -d: -f1)"

  if [ -n "$start" ]; then
    # Replace the existing block: from its opening line through the first
    # following `};` at the same indentation. Matching on indentation rather
    # than counting braces is what keeps a nested `keyboard = { … };` from
    # ending the block early.
    indent="$(sed -n "${start}p" "$out" | sed -E 's/^([[:space:]]*).*/\1/')"
    end="$(awk -v s="$start" -v ind="$indent" 'NR > s && $0 ~ ("^" ind "\\};[[:space:]]*$") { print NR; exit }' "$out")"
    [ -n "$end" ] || die "found 'custom.locale = {' at $out:$start but no matching '};' at the same indentation; fix it by hand"
    {
      head -n "$((start - 1))" "$out"
      printf '%s\n' "$fragment"
      tail -n "+$((end + 1))" "$out"
    } >"$tmp"
  else
    # Insert before the final closing brace of the file.
    last="$({ grep -n -E '^\}[[:space:]]*$' "$out" || true; } | tail -n 1 | cut -d: -f1)"
    [ -n "$last" ] || die "$out has no closing '}' on a line of its own; add the fragment by hand"
    prev="$(sed -n "$((last - 1))p" "$out")"
    {
      head -n "$((last - 1))" "$out"
      if [ -n "$prev" ]; then printf '\n'; fi
      printf '%s\n' "$fragment"
      tail -n "+$last" "$out"
    } >"$tmp"
  fi
fi

mv -- "$tmp" "$out"
trap - EXIT

say "  $action  $out"
say ""
printf '%s\n' "$fragment" >&2
say ""
say "  Review that file, then:  sudo nixos-rebuild switch --flake .#nixos --impure"
say "                                                                    ^^^^^^^^"
say "  --impure is REQUIRED. Without it this file is silently ignored and you"
say "  get America/Los_Angeles back with a successful build."

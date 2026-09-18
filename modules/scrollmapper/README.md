# Scrollmapper for Oligarchy

Version 1.0.1. Low-footprint NixOS flake module. Reads
[Scrollmapper bible_databases](https://github.com/scrollmapper/bible_databases)
from the terminal and plants a verse in the **boot dialogue**.

Default **canon filter**: Eastern Orthodox (Septuagint / anagignoskomena).
Default **text**: KJVA (public-domain KJV + Apocrypha). That is the closest
permissive English set Scrollmapper ships. It is not the Orthodox Study Bible.

The Godot app is not packaged. Boot never loads the 10 MiB JSON.

See `AUDIT.md` for the adversary review that produced 1.0.1.

## Boot dialogue

`scrollmapper-boot-dialogue.service` runs in `sysinit` (5 s cap, cannot fail the boot):

1. Random line from the Orthodox display pool (`boot-pool.tsv`, 143 verses).
2. `plymouth display-message` when Plymouth is on.
3. ASCII banner on `/dev/console`.
4. `/run/scrollmapper/{verse,ref,text,plymouth}`.
5. Static fallback in `/etc/issue.d/50-scrollmapper.issue` (`%` escaped).
6. If `services.boot-intro.enable`, `bottomText` is `mkDefault` to John 1:1
   (rebuild-stable; Plymouth stays random per boot).

## Install into Oligarchy

Copy this directory to `modules/scrollmapper/`.

```nix
# flake.nix inputs
scrollmapper.url = "path:./modules/scrollmapper";
# do NOT follow a second nixpkgs; let the root flake lock this path

# outputs args
, scrollmapper

# commonModules
scrollmapper.nixosModules.scrollmapper
```

```nix
custom.scrollmapper = {
  enable = true;
  translation = "KJVA";
  canon = "orthodox";
  bootDialogue.enable = true;
  dailyVerse.enable = true;
};
```

## CLI

```
scrollmapper daily              # curated pool, date-hashed
scrollmapper daily --full       # whole installed translation
scrollmapper read John 1:1-5
scrollmapper read Psalms 50
scrollmapper read Wisdom 3:1
scrollmapper search "light of the world"
scrollmapper books
scrollmapper info
```

`nix run path:./modules/scrollmapper#daily`

## Options

| option | default | purpose |
|---|---|---|
| `custom.scrollmapper.enable` | off | install reader + boot hook |
| `custom.scrollmapper.translation` | `KJVA` | `KJVA` `KJV` `CPDV` `ASV` `BSB` |
| `custom.scrollmapper.canon` | `orthodox` | `orthodox` `catholic` `protestant` `full` |
| `custom.scrollmapper.aliases` | `false` | `sm` / `verse` |
| `custom.scrollmapper.bootDialogue.enable` | `true` | Plymouth / console / issue |
| `custom.scrollmapper.bootDialogue.console` | `true` | write `/dev/console` |
| `custom.scrollmapper.dailyVerse.enable` | `false` | date-hashed verse |
| `custom.scrollmapper.dailyVerse.notify` | `false` | user timer + notify-send |

`3 Maccabees` and `Psalm 151` are listed in the Orthodox filter and appear
only when the translation contains them. KJVA does not.

## License

Module code is BSD-3 (same family as Oligarchy). Scripture bytes follow
upstream translation terms. See `LICENSE`.

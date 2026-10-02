# Installing Oligarchy

## What was wrong

The ISO's graphical installer was nixpkgs' stock Calamares. Its install step
writes a generic `/etc/nixos/configuration.nix` and runs `nixos-install`. So
installing from the Oligarchy ISO produced **plain NixOS**. Getting to
Oligarchy then meant cloning the flake, copying UUIDs into a
`hosts/<target>/hardware-configuration.nix` by hand, running `oligarchy-adopt`
for the locale, and remembering `--impure`. `oligarchy-hw-detect` printed
those steps.

## What it does now

1. **Target page.** This replaces upstream's desktop and unfree pages. It
   offers `installTargets` from `flake.nix` (Framework 16, Framework 13, Intel,
   Intel + Nvidia), plus **Plain NixOS**, which runs upstream's unmodified job.
2. **Install step** (`installer/calamares/distroinstall/main.py`):
   - It copies this flake, the ISO's own revision, to `/mnt/etc/nixos`. Any
     existing `/etc/nixos` is moved aside to `/etc/nixos.before-Oligarchy`.
   - It writes the hardware scan and your answers to `hosts/installed/`.
   - It runs `nixos-install --flake /mnt/etc/nixos#installed`.
3. **`mkInstalled`** (`flake.nix`) builds the chosen target with two things
   swapped: its hardware file becomes the scan, and its host name becomes
   yours. Every other module, the plugin runtime and the P2P substituter
   included, is the target's, in the same order.

`installer/installed.nix` maps your answers:

| answer | becomes |
|---|---|
| language, formats | `custom.locale.language` / `glibcLocale` / `region`, normalised the way `oligarchy-adopt` does it |
| time zone, keyboard | `custom.locale.timeZone`, `custom.locale.keyboard.{layout,variant}` (the console keymap is derived from xkb, as locale.nix intends) |
| user | `custom.user.name` and `fullName`; `email = null`; **`sshAuthorizedKeys` emptied**, so the maintainer's keys do not follow the distribution onto your machine |
| autologin | `custom.session.autoLogin.enable` (greetd's `initial_session`) |
| BIOS | GRUB on the named disk, in place of systemd-boot |
| LUKS | encrypted swap, and the GRUB-cryptodisk keyfile |

The git identity in `home/apps/default.nix` now reads `custom.user.fullName`
and `custom.user.email`. Before, every account committed as the maintainer.
The defaults are the maintainer's. `.#nixos`, `.#nixos-fw13`, `.#nixos-intel`,
`.#nixos-optimus` and `.#builder` were evaluated before and after this
change, and their derivations are identical. `.#nixos-asher` could not be
evaluated where this was written: its evaluation builds a disk image, which
needs KVM. It is `.#nixos` plus an unchanged `hosts/asher`, so it is unchanged
by construction, but that is an argument, not a measurement.

## On the installed machine

```bash truth:ignore
sudo nixos-rebuild switch --flake /etc/nixos#installed
```

No `--impure`: the override channel for an installed machine is
`/etc/nixos/hosts/installed/local.nix`, inside the flake, and it is imported
when it exists. `custom.localOverrides.expected` is false there, so pure
evaluation has nothing to warn about.

`/etc/nixos` is a copy, not a git checkout. If you `git init` it, also
`git add hosts/installed`: a git flake sees only tracked files, and without
them `#installed` disappears.

## From a TTY: `oligarchy-install`

```bash truth:ignore
# partition, format and mount under /mnt first
sudo oligarchy-install --profile nixos-fw13 --user maria --hostname werkbank \
    --timezone Europe/Berlin --locale de_DE.UTF-8 --keyboard de:nodeadkeys
oligarchy-install --profile nixos --user maria --dry-run    # prints install.json, touches nothing
```

It runs the same job module as the graphical installer. Encrypted swap and
GRUB with an encrypted `/boot` are graphical-installer only.

## The ISO's SSH

sshd runs at boot on every NixOS installer image. This ISO also published a
password (`nixos`/`nixos`, passwordless sudo) with password authentication on.
The firewall admits :22 only on `tailscale0`, so the exposure was your tailnet,
if the live session ever joined it. Password and keyboard-interactive
authentication are now off on the ISO. A key in `~nixos/.ssh/authorized_keys`
still works.

## Gates

| gate | what it does | cost |
|---|---|---|
| `.#installer-unit` | Runs the job's 9 unit tests against this nixpkgs' real upstream job. It also checks the generated `settings.conf`, that a doctored upstream fails the build (the drift guard), and `oligarchy-install --dry-run`. | seconds |
| `.#installer-contract` | Evaluates the Framework 16 fixture (UEFI, German) and the Intel fixture (BIOS, LUKS, autologin), plus one with a future schema. It asserts the target is kept, and that the host name, account, locale, boot loader and LUKS are the user's. It also asserts that no maintainer key and no maintainer git identity survive. | three system evaluations; `legacyPackages` |

## Not verified

- `[UNTESTED]` A graphical install, clicked through and booted.
- `[UNTESTED]` An offline install. Like upstream's job, `nixos-install`
  fetches what the ISO's store does not hold.
- The installed tree is all 119 MB of tracked files, `assets/` included,
  because it is the flake the ISO was built from.

## Why this reverses docs/localization-roadmap.md §6

§6 rejected "make Calamares write a flake" and chose `oligarchy-adopt`. The
reversal and how each objection is met are recorded there, under §6.

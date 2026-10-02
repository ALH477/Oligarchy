# installer/

The ISO's installer installs Oligarchy itself. The user guide is
`docs/installer.md`; this file covers where the code comes from.

| file | origin | role |
|---|---|---|
| `calamares/distroinstall/main.py`, `module.desc` | ArchibaldOS `installer/` (vendored) | the Calamares job: copy this flake to `/etc/nixos`, write `hosts/installed/`, run `nixos-install --flake …#installed` |
| `calamares/extensions.nix` | ArchibaldOS (vendored) | rebuilds `calamares-nixos-extensions` with the job and a target page; refuses an upstream it does not know |
| `calamares/tests/test_distroinstall.py` | ArchibaldOS (vendored) | the job's unit tests, run against the real upstream job by `.#installer-unit` |
| `cli.py`, `cli.nix` | ArchibaldOS (vendored) | `oligarchy-install`: the same job from a TTY |
| `iso.nix` | ArchibaldOS (vendored) | the overlay an ISO imports |
| `installed.nix` | Oligarchy | `install.json` → `custom.locale.*`, `custom.user.*`, boot loader, LUKS |

## Vendored, not an input

ArchibaldOS is not a flake input here: the commented-out `archibaldos` input
in `flake.nix` is still a placeholder, and pulling in that flake's whole lock
for seven small files would cost more than it saves. So these files are
copies, and **the rule is that they stay byte-identical with ArchibaldOS**.
A change goes to both trees in the same piece of work. These files are
BSD-3-Clause, copyright DeMoD LLC, as in ArchibaldOS. The rest of this tree is
BSD-3-Clause under its own copyright line.

The job is distribution-neutral by design. Everything distribution-specific
comes in through its configuration (`distroinstall.conf`: name, source,
profile ids, default) and through each tree's own `installed.nix`.

## Two upstreams

nixos-25.11 (this tree) and nixos-unstable (ArchibaldOS) both ship
`calamares-nixos-extensions` 0.3.23, with different contents. The 25.11 job
has no `NixProgress` and no `fix_btrfs_subvolumes`, and its `settings.conf`
gives the `nixos` job no progress weight. The job uses either helper only
when it exists, and `extensions.nix` accepts both known shapes and nothing
else. The unit tests run against whichever upstream the tree pins, so each
tree tests its own.

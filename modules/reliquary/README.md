# Reliquary

A Nix flake for **cold preservation** of a directory tree across three
places you can hold in your hands:

1. A local staging store (content-addressed blocks).
2. **Two duplicated 256 GB USB flash drives**, each with its own dedicated
   partitions (`RLQ-META-*` + `RLQ-DATA-*`).
3. A **writable CD-R** of each CD-sized data block.

Every block is a GNU tar + zstd payload, SHA-256/512 manifests, and 20 %
PAR2 recovery volumes. The same directory layout is what lands on USB and
what is burned to CD.

An operator drives this with `reliquary` on the CLI, a ratatui TUI
(`reliquary tui`) that can browse and pack directories, or a stdio
**MCP server** (`reliquary mcp`) so an agent can ingest, copy, verify,
extract, and build ISOs.

## Quick start

```bash
nix develop github:you/reliquary          # or: cd this repo && nix develop
export RELIQUARY_STORE=$PWD/.reliquary-work/store

reliquary ingest ~/documents --profile cd
reliquary list
reliquary verify 20260915-aaaaaaaaaaaaaaaa
reliquary extract 20260915-aaaaaaaaaaaaaaaa /tmp/restored
```

On a machine with the two sticks plugged in and mounted by label:

```bash
sudo reliquary usb format /dev/sdX --role A --confirm WIPE-THIS-USB
sudo reliquary usb format /dev/sdY --role B --confirm WIPE-THIS-USB
# mount -L RLQ-DATA-A ... (or enable the NixOS module)
reliquary push 20260915-aaaaaaaaaaaaaaaa          # copies onto A and B
reliquary iso  20260915-aaaaaaaaaaaaaaaa          # writes store/iso/*.iso
reliquary burn ~/.local/share/reliquary/iso/20260915-aaaaaaaaaaaaaaaa.iso /dev/sr0
```

## What a block is

```
~/.local/share/reliquary/blocks/<YYYYMMDD-sha256prefix>/
  manifest.json
  payload.tar.zst
  SHA256SUMS
  SHA512SUMS
  payload.tar.zst.par2
  payload.tar.zst.vol00+01.par2
  ...
```

- **tarball** — GNU tar, sorted names, zeroed owner, epoch mtime, piped
  through `zstd -19`.
- **checksum** — SHA-256 and SHA-512 of every file in the block.
- **PAR2** — `par2 create -r20 -n4 -u` so a damaged USB stick or a
  scratched CD can still reconstruct the payload.

`profile=cd` (default) refuses a block that will not fit an 80-minute
CD-R after PAR2 and ISO overhead. `profile=usb` drops that cap for trees
that only live on the 256 GB pair.

## USB pair (256 GB × 2)

Each stick is independently formatted:

| Partition | Size     | Filesystem | Label A / B              |
|-----------|----------|------------|--------------------------|
| 1         | 2 GiB    | FAT32      | `RLQ-META-A` / `RLQ-META-B` |
| 2         | rest     | ext4       | `RLQ-DATA-A` / `RLQ-DATA-B` |

META holds `catalog.json` + a README that explains how to verify the
stick on a machine that has never seen Reliquary. DATA holds
`blocks/<id>/` copies.

The sticks are **duplicates**, not halves. Push writes the same block to
both. If one dies, the other plus any CD-R of that block still verify.

Details: [`docs/MEDIA.md`](docs/MEDIA.md).

## TUI

```bash
reliquary tui
```

The left pane is a directory browser. Highlight `.` or a child folder and
pack it into a block without typing a path.

| Key | Action |
|-----|--------|
| `Tab` | Switch directory pane ↔ block list |
| `j` / `k` | Move |
| `Enter` | Open the highlighted directory, or pack `.` / a file |
| `b` or `Space` | Pack the highlighted directory into a block |
| `h` / Backspace | Parent directory |
| `c` | Toggle `cd` / `usb` profile |
| `v` `p` `i` | Verify / push USBs / make ISO for the highlighted block |
| `:` | Command (`:cd /path`, `:extract ID /dest`) |

## MCP

Stdio server, no extra SDK. Point a host at the wrapped binary:

```json
{
  "mcpServers": {
    "reliquary": {
      "command": "reliquary",
      "args": ["mcp"]
    }
  }
}
```

Tools: `reliquary_status`, `reliquary_list_blocks`, `reliquary_show_block`,
`reliquary_ingest`, `reliquary_verify`, `reliquary_extract`,
`reliquary_push_usb`, `reliquary_pull_usb`, `reliquary_make_cd_iso`,
`reliquary_burn_cd`, `reliquary_usb_status`.

See [`examples/mcp.json`](examples/mcp.json).

## Nix

```nix
# flake.nix consumer
{
  inputs.reliquary.url = "path:/abs/to/reliquary";
  outputs = { reliquary, ... }: {
    nixosConfigurations.box.modules = [
      reliquary.nixosModules.reliquary
      { services.reliquary.enable = true; }
    ];
  };
}
```

The module installs the package, sets `RELIQUARY_STORE=/var/lib/reliquary`,
and automounts the four labelled partitions under `/mnt/reliquary/`.

```bash
nix run . -- status
nix run . -- tui
nix run . -- mcp
```

Wrapped onto PATH with the package: `par2`, `tar`, `zstd`, `xorriso`,
`sgdisk`, `mkfs.vfat`, `mkfs.ext4`, `lsblk`, `rsync`.

## Environment

| Variable                     | Default                                      |
|------------------------------|----------------------------------------------|
| `RELIQUARY_STORE`            | `$XDG_DATA_HOME/reliquary` or `~/.local/share/reliquary` |
| `RELIQUARY_WORK`             | `$STORE/work`                                |
| `RELIQUARY_PAR2_REDUNDANCY`  | `20`                                         |

## Restore without Reliquary

```bash
sha256sum -c SHA256SUMS
par2 verify payload.tar.zst.par2   # par2 repair if needed
tar -xf payload.tar.zst
```

## Safety

`reliquary usb format` will not run unless `--confirm WIPE-THIS-USB` is
passed, and it aborts if any partition of the target device is mounted.
It still destroys the whole disk. Check `lsblk` twice.

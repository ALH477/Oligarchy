# Reliquary media layout

## Two 256 GB USB flash drives (duplicated pair)

Each stick is a whole-disk Reliquary volume. They are mirrors, not a RAID
stripe. Either stick is sufficient to restore every block that was pushed
while both were present.

Format (destroys the device):

```
sudo reliquary usb format /dev/sdX --role A --confirm WIPE-THIS-USB
sudo reliquary usb format /dev/sdY --role B --confirm WIPE-THIS-USB
```

### GPT partitions on each stick

| Part | Size    | FS    | Label (role A / B)     | Role |
|------|---------|-------|------------------------|------|
| 1    | 2 GiB   | FAT32 | `RLQ-META-A` / `B`     | Catalog, README, offline checksums. Readable on any OS. |
| 2    | remainder (~230+ GiB on a "256 GB" stick) | ext4 | `RLQ-DATA-A` / `B` | One directory per block. |

FAT32 volume labels are truncated to 11 characters; these labels fit.

### Why two partitions

- The catalog partition stays mountable on machines that cannot read ext4.
- A corrupted data filesystem does not take the catalog with it.
- You can re-`mkfs` DATA and restore blocks from the sibling stick or from CD-R.

### Mounting without the NixOS module

```
mkdir -p /mnt/reliquary/{meta-a,data-a,meta-b,data-b}
mount -L RLQ-META-A /mnt/reliquary/meta-a
mount -L RLQ-DATA-A /mnt/reliquary/data-a
mount -L RLQ-META-B /mnt/reliquary/meta-b
mount -L RLQ-DATA-B /mnt/reliquary/data-b
```

## Writable CD-R data block

`profile=cd` (the default ingest profile) refuses a packed block that cannot
fit on an 80-minute CD-R after 20 % PAR2 and ISO overhead.

Capacity used by Reliquary:

- Physical 80-minute CD-R = `80 * 60 * 75 * 2048` = 737 280 000 bytes
- Default payload budget = 520 MiB compressed
- PAR2 redundancy = 20 % in 4 uniform volumes
- Image = ISO 9660 + Rock Ridge + Joliet of the block directory

```
reliquary ingest ~/papers --profile cd
reliquary iso 20260915-aaaaaaaaaaaaaaaa
reliquary burn ~/.local/share/reliquary/iso/20260915-aaaaaaaaaaaaaaaa.iso /dev/sr0
```

`--dummy` on `burn` runs xorriso with the laser off.

Larger trees use `--profile usb` and live only on the two sticks (and the
local staging store). Split a tree yourself if you want every piece on CD-R.

## Block directory (same on disk, USB DATA, and CD)

```
<block-id>/
  manifest.json
  payload.tar.zst
  SHA256SUMS
  SHA512SUMS
  payload.tar.zst.par2
  payload.tar.zst.vol00+01.par2
  ...
```

`block-id` is `YYYYMMDD-` plus the first 16 hex characters of the payload
SHA-256. Identical input therefore collapses to the same block.

Tarball flags: `--sort=name --mtime=UTC 1970-01-01 --owner=0 --group=0
--numeric-owner` so a bit-identical tree packs to a bit-identical payload.

## Offline verify (no Reliquary required)

```
sha256sum -c SHA256SUMS
par2 verify payload.tar.zst.par2
tar -xf payload.tar.zst
```

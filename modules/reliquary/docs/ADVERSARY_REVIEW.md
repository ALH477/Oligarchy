# Adversary review — Reliquary 0.1.0

Review stance: the operator is trusted, the media is not, USB labels
are attacker-controlled, MCP hosts are prompt-injectable, and the
payload tarball may one day be someone else's.

## Fixed in this tree

1. **Push invalidated checksums.** `copy_block` used to rewrite
   `manifest.json` after `SHA256SUMS` was written. Verify on the USB
   copy always failed. Copies now go to `copies.json`; sums cover only
   `payload.tar.zst` and the PAR2 set.
2. **Block-id path traversal.** `block_id` from CLI/MCP/TUI is now
   `YYYYMMDD-` + 16 hex chars. `../` no longer walks out of the store.
3. **Tar slip on extract.** The archive listing is scanned for `..` and
   absolute members before `tar -x`. Extract uses `--no-same-owner`.
4. **Format window.** `usb format` refuses devices outside 64–512 GB and
   refuses anything mounted on `/`, `/boot`, `/nix`, or `/home*`.
5. **Flake packaged the Python prototype.** The flake now builds the
   Rust crate.

## Still open — do not ignore

### Integrity

- No signature. A rewritten payload + regenerated PAR2 + matching
  SUMS is indistinguishable from the original. Add minisign/SSH sign
  of `SHA256SUMS` before calling this an archive of record.
- Block ids embed only 64 bits of the SHA-256. Collisions are not
  practical for accident, but the id is not a sufficient binding.
  Always verify the full digest in the manifest.
- Same tree ingested on two calendar days produces two block ids.
  Dedup is same-UTC-day only.
- No `fsync` / `syncfs` after write. A power loss mid-push can leave a
  torn copy that still has a catalog entry.
- PAR2 is 20 %. That is a reasonable optical default, not a substitute
  for a third off-site copy.
- `tar --sort=name` + epoch mtime is GNU-tar specific. BusyBox tar
  will not reproduce the payload.

### USB / optical

- Detection is **filesystem label**. Anyone can `mkfs -L RLQ-DATA-A`.
  The NixOS module automounts by label. Pin by PARTUUID once the pair
  is minted, or Reliquary will happily write the archive onto a
  hostile stick.
- That forgery was not only an integrity problem. Until fixed, the four
  automounts carried no `nosuid,nodev,noexec`, so a forged-label ext4
  stick — whose on-disk permission bits are honored — could carry a
  setuid root binary that any local user then executed as root. The
  automount fires on first *access*, which `reliquary status` and the
  TUI's volume reads do unprompted, so it needed no cooperation beyond
  the stick being present. All four mounts now carry the three flags;
  nothing is ever executed from these volumes, so it costs nothing.
  Label forgery remains an integrity weakness — PARTUUID pinning is
  still the real fix.
- `format` still takes a raw `/dev/sdX`. The phrase `WIPE-THIS-USB`
  is the only interlock besides size. Read `lsblk -o NAME,MODEL,SERIAL,SIZE`
  twice.
- Push does not verify the destination after copy. A failing flash
  cell is silent until the next `verify`.
- Two sticks are a mirror, not a quorum. Both can be written from the
  same corrupted local block in one `push`.
- CD-R ISO is built from the local block, not from a verified USB
  copy. Burn after `verify`, not after `ingest` alone.
- ext4 on USB flash will wear. f2fs or a read-mostly mount (`ro,noatime`)
  after the write pass would be healthier.

### MCP / TUI / process

- The MCP server is unauthenticated stdio and can ingest arbitrary
  paths, extract to arbitrary dests, push onto mounted volumes, and
  burn `/dev/sr0`. Treat the host as root-equivalent for media.
- `reliquary_burn_cd` and `reliquary_push_usb` should require an
  explicit confirmation argument before an agent is allowed to use
  them in production.
- TUI ingest is synchronous. A large tree freezes the UI; there is
  no cancel and no progress.
- Shared `work/ingest` directory: two concurrent ingests clobber
  each other.

### Supply / build

- `Cargo.lock` must exist for the flake. Generate it on a machine
  with crates.io before `nix build`.
- Tool lookup walks `PATH` and takes the first executable `par2` /
  `tar` / `xorriso`. A user-writable `PATH` prefix wins. The Nix
  wrapper is the intended fix; a raw `cargo run` is not.

### Residual Python

- `legacy/python` is the prototype. Do not ship it on PATH. Do not
  format USB sticks with it; it still mutates `manifest.json` on push.

## Operator checklist before real data

- [ ] `cargo test` / at least `cargo run -- status`
- [ ] Ingest a known tree, `sha256sum -c SHA256SUMS`, `par2 verify`
- [ ] Push to *one* stick, unplug, verify on a second machine
- [ ] Push to the sibling, compare payload SHA-256
- [ ] Build ISO from a *verified* block, `xorriso -indev` listing
- [ ] Record PARTUUIDs of both sticks on paper
- [ ] Sign `SHA256SUMS` (minisign) and keep the public key off the sticks

# BIOS iGPU UMA carve-out unlock — runbook

## Read this first

This is firmware modification, not NixOS configuration. It operates on your
laptop's SPI flash chip through the platform's UEFI variable services, not
through anything Nix, the kernel, or this repo's build/boot path controls.
Getting it wrong can leave the machine unable to POST. Recovery in that case
is normally "hold the power button / clear CMOS to force Setup defaults",
which recovers most single-variable mistakes — but a corrupted Setup NVRAM
blob or a bad write to the wrong variable can require re-flashing the chip
with an external SPI programmer (e.g. a CH341A) from the backup this runbook
makes you take in step 1. There is no code path here that avoids that risk;
the tooling below exists to make the *process* as careful as possible, not to
make the underlying operation safe.

**Nothing in this repo's Nix build, ISO, or `nixos-rebuild` ever runs this.**
It's a standalone `nix develop` shell you enter by hand, on purpose, once.

**A VM cannot de-risk this.** QEMU/OVMF is TianoCore/edk2 — a different
firmware codebase from Framework's Insyde H2O. It has none of the same Setup
formsets, no `UMA_SPECIFIED`-equivalent variable, and none of the real AGESA
PEI/DXE reinit path the write depends on. You can (and should) test the
*plumbing* of a UEFI Shell tool under OVMF; you cannot test whether a given
variable/offset write is safe on your actual board — only the real hardware
exercises that path.

## Why this exists

AMD Phoenix (7040-series) APU platforms carve out a fixed block of system RAM
for the iGPU's UMA framebuffer before the OS ever boots. Framework's BIOS
Setup exposes this as an "IGD"/"UMA" frame-buffer-size field (commonly `Auto`,
or a fixed step like 512M/1G/2G/4G). If your unit's visible Setup menu
already offers a value near 256–512M, **use that — reboot, F2, change it,
done, skip this entire document.** This runbook is only for the case where
the field is present in firmware (nearly all AGESA-based Setup builds have
it) but not exposed as a selectable option in the shipped menu, which is a
menu-visibility restriction the vendor applied at build time, not a hardware
limit.

## Step 0 — confirm the menu really doesn't expose it

Boot into Setup (F2 at power-on) and check every page under `Advanced` /
`Chipset` / `North Bridge` / `Graphics Configuration` (naming varies by BIOS
version) for anything mentioning UMA, IGD, iGPU, or Frame Buffer Size. Some
Framework BIOS updates have added this as a visible option after community
requests — check your current BIOS version against Framework's release notes
before assuming you need the unlock path at all.

## Step 1 — mandatory backup (read-only, safe)

```
nix develop .#bios-tools
sudo flashrom -p internal -r backup-1.rom
sudo flashrom -p internal -r backup-2.rom
sha256sum backup-1.rom backup-2.rom   # MUST match — if not, do not proceed
```

Two independent reads that hash-match confirm a clean, non-corrupted dump.
Copy `backup-1.rom` off the machine (another drive, another computer) before
touching anything else. This file is your recovery path if a physical
SPI-programmer reflash ever becomes necessary — it is not consumed by any
later step, it just needs to exist and be intact.

## Step 2 — find your board's actual variable (offline, safe, on the dump)

This has to be done against *your* dumped image; there is no fixed answer to
publish here; the exact `VarStore` GUID, name, and byte offset for the UMA
size field are specific to your BIOS version and are not something I can
determine without your dump.

```
uefitool backup-1.rom          # GUI: locate the Setup Utility's PE32 module,
                                # extract its raw section
ifrextractor-rs <extracted-section> ifr-out.txt
grep -in -A3 -B3 'uma\|igd\|frame.*buffer\|graphics.*memory' ifr-out.txt
```

Look for a `Question` block referencing a UMA/IGD size field. It will name a
`VarStoreId`, and the `Offset` field tells you the byte position inside that
VarStore's NVRAM variable (almost always named `Setup`, GUID varies by
vendor/BIOS build — read it off the `VarStore` definition in the same IFR
dump, don't assume). Note the `Offset`, the size (1 byte is typical for an
enum-style field), and the numeric values IFREXtractor lists for each visible
*and* hidden option under that Question (`Auto`, `32M`, `64M`, ... up to the
2G/4G values the visible menu already offers) — you need the raw option
value for your target size (closest to 256M), not just its label.

If you can't confidently identify the field from this output, stop here.
Guessing which offset is "probably" the UMA field and writing to it anyway is
exactly the failure mode this process exists to prevent.

## Step 3 — read the live variable, confirm your offset, write, verify

```
nix develop .#bios-tools
oligarchy-bios-uma-unlock read   <VarName> <VarGuid>
# inspect the printed hex dump; find your byte at <offset> and confirm its
# current value matches what step 2 predicted for the currently-selected
# (2G) option before changing anything

oligarchy-bios-uma-unlock write  <VarName> <VarGuid> <offset> <new-hex-value> \
    --backup backup-1.rom
# requires typing the literal confirmation phrase the tool prompts for;
# refuses to run without --backup pointing at an existing, readable file
```

`oligarchy-bios-uma-unlock` is a thin wrapper around `chipsec_util uefi
var-read <name> <GUID> <file>` / `var-write <name> <GUID> <file>` (see
`devShells.bios-tools` in `flake.nix`) — this exact syntax has been verified
against chipsec 1.13.17, the version `devShells.bios-tools` actually builds
from this flake's pinned `nixos-25.11` nixpkgs (`chipsec_util uefi --help`
output checked directly, not assumed). It edits **one byte inside the
existing variable blob** via the platform's normal `GetVariable`/`SetVariable`
UEFI runtime services — it does not touch the SPI flash directly — reads the
current value back after writing and shows you a before/after diff so a
failed or partial write is visible immediately rather than discovered at next
boot.

What is *not* verified, and can't be from here: whether `var-read`/`var-write`
on your specific machine go through the OS's `efivarfs` path or chipsec's own
driver, whether that driver loads cleanly against your running kernel, and
obviously the actual effect of writing to your board's real UMA-size
variable. Those only get exercised on real hardware, by you.

## Step 4 — reboot and confirm

Reboot into Setup and check the field reflects the new value (if it's now
visible) or check `dmesg`/`amdgpu` VRAM reporting after boot
(`cat /sys/kernel/debug/dri/*/amdgpu_vram_mm` or `glxinfo`/`vulkaninfo` VRAM
size) to confirm the carve-out actually shrank. If the system fails to POST:
hold the power button ~10s (forces most Insyde/AMI implementations to reset
Setup to defaults on next boot) before considering a physical SPI reflash
from `backup-1.rom` with an external programmer.

## What I am not going to do

I'm not going to hand you a Framework-16/13-specific variable name and offset
in this document, because I don't have your BIOS dump and any offset I gave
you would be a guess dressed up as a fact. That guess is exactly the kind of
mistake that bricks boards. Steps 1–2 above exist so the number you actually
write in step 3 came from your own firmware, not from me.

"""Build and optionally burn a CD-R image of one Reliquary block."""

from __future__ import annotations

from pathlib import Path

from reliquary.config import Config
from reliquary.store import Store, StoreError
from reliquary.util import require_tool, run


def make_iso(cfg: Config, store: Store, block_id: str) -> Path:
    block = store.block_dir(block_id)
    if not block.exists():
        raise StoreError(f"unknown block {block_id}")

    volid = ("RLQ" + block_id.replace("-", ""))[:32]
    iso = cfg.iso_root / f"{block_id}.iso"
    iso.parent.mkdir(parents=True, exist_ok=True)
    if iso.exists():
        iso.unlink()

    xorriso = require_tool("xorriso")
    # Rock Ridge + Joliet so the block is readable on Unix and Windows.
    run(
        [
            xorriso,
            "-as",
            "mkisofs",
            "-R",
            "-J",
            "-V",
            volid,
            "-o",
            str(iso),
            str(block),
        ],
        check=True,
    )
    size = iso.stat().st_size
    if size > cfg.cd_capacity_bytes:
        iso.unlink()
        raise StoreError(
            f"ISO is {size} bytes, larger than an 80-minute CD-R "
            f"({cfg.cd_capacity_bytes}). Use profile=usb or split the source."
        )
    return iso


def burn_iso(iso: Path, device: Path, *, dummy: bool = False) -> dict:
    xorriso = require_tool("xorriso")
    args = [
        xorriso,
        "-as",
        "cdrecord",
        f"dev={device}",
        "-v",
        str(iso),
    ]
    if dummy:
        args.insert(-1, "-dummy")
    proc = run(args, check=True)
    return {"ok": True, "device": str(device), "iso": str(iso), "log": proc.stdout}


def iso_info(iso: Path) -> dict:
    return {
        "path": str(iso),
        "bytes": iso.stat().st_size if iso.exists() else 0,
        "exists": iso.exists(),
    }

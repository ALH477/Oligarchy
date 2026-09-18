"""Deterministic-ish tarball + zstd payload packing."""

from __future__ import annotations

import os
from pathlib import Path

from reliquary.util import require_tool, run


def pack_tree(source: Path, dest_tar_zst: Path, *, zstd_level: int = 19) -> dict:
    """Create a compressed tarball of `source`.

    Uses GNU tar + zstd. Paths inside the archive are relative to the
    source parent so a single top-level directory name is preserved.
    """
    source = source.resolve()
    dest_tar_zst.parent.mkdir(parents=True, exist_ok=True)
    tar = require_tool("tar")
    zstd = require_tool("zstd")

    parent = source.parent
    name = source.name
    members = [name]

    tmp = dest_tar_zst.with_suffix(".partial")
    # GNU tar --sort=name + fixed mtime makes two ingestions of an
    # unchanged tree produce byte-identical payloads.
    # Stream via a real pipeline so we don't buffer multi-GB in Python.
    import subprocess

    with tmp.open("wb") as out:
        t = subprocess.Popen(
            [
                tar,
                "--sort=name",
                "--mtime=UTC 1970-01-01",
                "--owner=0",
                "--group=0",
                "--numeric-owner",
                "-C",
                str(parent),
                "-cf",
                "-",
                "--",
                *members,
            ],
            stdout=subprocess.PIPE,
        )
        z = subprocess.Popen(
            [zstd, f"-{zstd_level}", "-T0"],
            stdin=t.stdout,
            stdout=out,
        )
        if t.stdout:
            t.stdout.close()
        zc = z.wait()
        tc = t.wait()
    if tc != 0 or zc != 0:
        tmp.unlink(missing_ok=True)
        raise RuntimeError(f"tar|zstd failed (tar={tc} zstd={zc})")
    tmp.replace(dest_tar_zst)

    listing = run([tar, "-tf", str(dest_tar_zst)], check=True)
    entries = [ln for ln in listing.stdout.splitlines() if ln]
    uncompressed = _estimate_uncompressed(dest_tar_zst)
    return {
        "file": dest_tar_zst.name,
        "bytes": dest_tar_zst.stat().st_size,
        "tar_entries": len(entries),
        "uncompressed_bytes": uncompressed,
        "source_name": name,
    }


def extract_payload(payload: Path, dest_dir: Path) -> None:
    dest_dir.mkdir(parents=True, exist_ok=True)
    tar = require_tool("tar")
    run([tar, "-C", str(dest_dir), "-xf", str(payload)], check=True)


def _estimate_uncompressed(payload: Path) -> int:
    """Best-effort uncompressed size from zstd frame header; 0 if unknown."""
    zstd = require_tool("zstd")
    proc = run([zstd, "-l", str(payload)], check=False)
    if proc.returncode != 0:
        return 0
    # zstd -l table: Frames/Skips/Packed/Compressed/Uncompressed/...
    for line in proc.stdout.splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 5 and parts[0] not in {"Frames", "Total"}:
            raw = parts[4].replace(",", "")
            try:
                return int(raw)
            except ValueError:
                continue
        if line.strip().startswith("Total") or "totals" in line.lower():
            pass
    return 0


def tree_bytes(path: Path) -> int:
    if path.is_file():
        return path.stat().st_size
    total = 0
    for root, _dirs, files in os.walk(path):
        for name in files:
            fp = Path(root) / name
            try:
                total += fp.stat().st_size
            except OSError:
                continue
    return total

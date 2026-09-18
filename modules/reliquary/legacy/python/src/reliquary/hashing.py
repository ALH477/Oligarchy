"""Streaming checksums used for manifests and verify passes."""

from __future__ import annotations

import hashlib
from pathlib import Path

ALGORITHMS = ("sha256", "sha512")
CHUNK = 1024 * 1024


def hash_file(path: Path) -> dict[str, str]:
    sha256 = hashlib.sha256()
    sha512 = hashlib.sha512()
    with path.open("rb") as fh:
        while True:
            buf = fh.read(CHUNK)
            if not buf:
                break
            sha256.update(buf)
            sha512.update(buf)
    return {"sha256": sha256.hexdigest(), "sha512": sha512.hexdigest()}


def write_sum_files(directory: Path, files: list[Path]) -> None:
    lines256: list[str] = []
    lines512: list[str] = []
    for f in files:
        digests = hash_file(f)
        rel = f.name
        lines256.append(f"{digests['sha256']}  {rel}\n")
        lines512.append(f"{digests['sha512']}  {rel}\n")
    (directory / "SHA256SUMS").write_text("".join(lines256), encoding="utf-8")
    (directory / "SHA512SUMS").write_text("".join(lines512), encoding="utf-8")


def verify_sum_file(directory: Path, name: str = "SHA256SUMS") -> list[str]:
    """Return a list of problem strings. Empty means all good."""
    sums = directory / name
    if not sums.exists():
        return [f"missing {name}"]
    algo = "sha256" if "256" in name else "sha512"
    problems: list[str] = []
    for line in sums.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        digest, _, filename = line.partition("  ")
        if not filename:
            digest, _, filename = line.partition(" *")
        target = directory / filename
        if not target.exists():
            problems.append(f"{filename}: missing")
            continue
        got = hash_file(target)[algo]
        if got != digest:
            problems.append(f"{filename}: {algo} mismatch")
    return problems

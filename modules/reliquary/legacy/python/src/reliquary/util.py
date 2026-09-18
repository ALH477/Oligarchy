"""Small process helpers."""

from __future__ import annotations

import shutil
import subprocess
from collections.abc import Sequence
from pathlib import Path


class ToolError(RuntimeError):
    pass


def require_tool(name: str) -> str:
    path = shutil.which(name)
    if not path:
        raise ToolError(
            f"required tool {name!r} is not on PATH. "
            "Enter the Reliquary Nix shell / package so preservation tools are wrapped in."
        )
    return path


def run(
    args: Sequence[str],
    *,
    cwd: Path | None = None,
    check: bool = True,
    capture: bool = True,
) -> subprocess.CompletedProcess[str]:
    proc = subprocess.run(
        list(args),
        cwd=cwd,
        text=True,
        capture_output=capture,
        check=False,
    )
    if check and proc.returncode != 0:
        tail = (proc.stderr or proc.stdout or "").strip()
        raise ToolError(f"command failed ({proc.returncode}): {' '.join(args)}\n{tail}")
    return proc

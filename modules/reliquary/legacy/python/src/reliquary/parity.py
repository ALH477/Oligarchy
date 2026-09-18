"""PAR2 create / verify / repair wrappers."""

from __future__ import annotations

from pathlib import Path

from reliquary.util import require_tool, run


def create_par2(
    target: Path,
    *,
    redundancy: int = 20,
    volumes: int = 4,
) -> dict:
    par2 = require_tool("par2")
    # -u uniform volume sizes; -n N recovery files; -r percent.
    run(
        [
            par2,
            "create",
            f"-r{int(redundancy)}",
            f"-n{int(volumes)}",
            "-u",
            "-q",
            str(target),
        ],
        cwd=target.parent,
        check=True,
    )
    siblings = sorted(target.parent.glob(target.name + "*.par2"))
    extra = sorted(target.parent.glob(target.name + ".vol*.par2"))
    index = target.parent / f"{target.name}.par2"
    return {
        "redundancy_percent": redundancy,
        "volumes": volumes,
        "index": index.name if index.exists() else (siblings[0].name if siblings else None),
        "files": [p.name for p in siblings],
        "recovery_files": [p.name for p in extra],
        "bytes": sum(p.stat().st_size for p in siblings),
    }


def verify_par2(index: Path) -> dict:
    par2 = require_tool("par2")
    proc = run([par2, "verify", "-q", str(index)], cwd=index.parent, check=False)
    ok = proc.returncode == 0
    return {
        "ok": ok,
        "returncode": proc.returncode,
        "output": (proc.stdout or "") + (proc.stderr or ""),
    }


def repair_par2(index: Path) -> dict:
    par2 = require_tool("par2")
    proc = run([par2, "repair", "-q", str(index)], cwd=index.parent, check=False)
    return {
        "ok": proc.returncode == 0,
        "returncode": proc.returncode,
        "output": (proc.stdout or "") + (proc.stderr or ""),
    }

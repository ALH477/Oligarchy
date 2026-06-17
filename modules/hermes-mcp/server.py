#!/usr/bin/env python3
"""
Hermes MCP — a dedicated, local, READ-ONLY Model Context Protocol server
exposing Hermes-specific introspection and the full read-only Oligarchy toolset.

Design goals (identical to oligarchy-mcp):
  * stdio transport only — no network, no LAN exposure.
  * Read-only — every tool inspects.
  * Re-uses the proven oligarchy-mcp implementation where possible.
  * Adds Hermes-specific tools: hermes_status, list_skills, session_summary.

Consumed by Claude Code / Blipply / agents via .mcp.json.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
import time
from pathlib import Path

from mcp.server.fastmcp import FastMCP

mcp = FastMCP("hermes-mcp")

# ──────────────────────────────────────────────────────────────────────────────
# Copy the minimal reusable pieces from oligarchy-mcp so we stay self-contained
# and avoid brittle dynamic imports at runtime.
# ──────────────────────────────────────────────────────────────────────────────

def _resolve_flake_dir() -> Path:
    env = os.environ.get("OLIGARCHY_FLAKE_DIR")
    if env:
        return Path(env).resolve()
    cwd = Path.cwd()
    if (cwd / "flake.nix").is_file():
        return cwd.resolve()
    return Path("/etc/nixos")


FLAKE_DIR = _resolve_flake_dir()
QUICK_TIMEOUT = 20
HEAVY_TIMEOUT = 900

_AUDIT_PATH = Path(
    os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state"))
) / "hermes-mcp" / "audit.log"


def _audit(tool: str, detail: str = "") -> None:
    try:
        _AUDIT_PATH.parent.mkdir(parents=True, exist_ok=True)
        with _AUDIT_PATH.open("a") as fh:
            fh.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')}\t{tool}\t{detail}\n")
    except OSError:
        pass


def _run(cmd: list[str], timeout: int = QUICK_TIMEOUT) -> str:
    if shutil.which(cmd[0]) is None:
        return f"[unavailable] {cmd[0]} is not on PATH"
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=timeout, check=False
        )
    except subprocess.TimeoutExpired:
        return f"[timeout] {' '.join(cmd)} exceeded {timeout}s"
    except OSError as exc:
        return f"[error] {exc}"
    out = (proc.stdout or "") + (proc.stderr or "")
    return out.strip() or f"[exit {proc.returncode}] (no output)"


# ──────────────────────────────────────────────────────────────────────────────
# Full read-only oligarchy tool surface (re-declared for hermes-mcp)
# ──────────────────────────────────────────────────────────────────────────────

@mcp.tool()
def system_status() -> str:
    """Kernel, host, power profile, DCF and AI status (one-line summary)."""
    _audit("system_status")
    return _run(["oligarchy-ctl", "status"])


@mcp.tool()
def dcf_status() -> str:
    """DeMoD Compute Fabric (DCF) mesh node status."""
    _audit("dcf_status")
    return _run(["hydramesh-status"])


@mcp.tool()
def dsp_status() -> str:
    """Real-time DSP coprocessor / audio status."""
    _audit("dsp_status")
    return _run(["dsp-status"])


@mcp.tool()
def ai_status() -> str:
    """Local Ollama AI stack status."""
    _audit("ai_status")
    return _run(["ai-stack", "status"])


@mcp.tool()
def service_status(unit: str) -> str:
    """systemctl status for a unit (read-only). Tries the user manager, then system."""
    _audit("service_status", unit)
    user = _run(["systemctl", "--user", "status", "--no-pager", "--lines", "0", unit])
    if "[unavailable]" in user or "could not be found" in user.lower():
        return _run(["systemctl", "status", "--no-pager", "--lines", "0", unit])
    return user


@mcp.tool()
def journal_tail(unit: str, lines: int = 50) -> str:
    """Last N journal lines for a unit (read-only). lines is clamped to 1..500."""
    n = max(1, min(int(lines), 500))
    _audit("journal_tail", f"{unit} n={n}")
    user = _run(["journalctl", "--user", "-u", unit, "-n", str(n), "--no-pager"])
    if "[unavailable]" in user or "No journal files" in user:
        return _run(["journalctl", "-u", unit, "-n", str(n), "--no-pager"])
    return user


@mcp.tool()
def list_modules() -> str:
    """List the .nix files in the Oligarchy flake repository."""
    _audit("list_modules")
    if not FLAKE_DIR.is_dir():
        return f"[error] flake dir {FLAKE_DIR} does not exist (set OLIGARCHY_FLAKE_DIR)"
    files = sorted(
        str(p.relative_to(FLAKE_DIR))
        for p in FLAKE_DIR.rglob("*.nix")
        if ".git" not in p.parts
    )
    return "\n".join(files) or "(no .nix files found)"


@mcp.tool()
def read_module(path: str) -> str:
    """Read a file from the flake repo. Path is sandboxed to FLAKE_DIR."""
    _audit("read_module", path)
    target = (FLAKE_DIR / path).resolve()
    if FLAKE_DIR not in target.parents and target != FLAKE_DIR:
        return "[denied] path escapes the flake directory"
    if not target.is_file():
        return f"[error] not a file: {path}"
    try:
        data = target.read_text(errors="replace")
    except OSError as exc:
        return f"[error] {exc}"
    if len(data) > 200_000:
        return data[:200_000] + "\n[... truncated ...]"
    return data


@mcp.tool()
def kernel_options() -> str:
    """Available custom.kernel.variant values."""
    _audit("kernel_options")
    return "zen, xanmod, latest, cachyos-bore (cachyos-bore is opt-in/experimental)"


@mcp.tool()
def gpu_options() -> str:
    """Available custom.platform.gpu values and the matching flake targets."""
    _audit("gpu_options")
    return "amd (.#nixos), intel (.#nixos), nvidia-optimus (.#nixos-optimus)"


@mcp.tool()
def dry_build(host: str = "nixos") -> str:
    """nixos-rebuild dry-build for a host. Heavy; may take minutes."""
    if host not in {"nixos", "nixos-intel", "nixos-optimus"}:
        return "[denied] host must be nixos | nixos-intel | nixos-optimus"
    _audit("dry_build", host)
    return _run(
        ["nixos-rebuild", "dry-build", "--flake", f"{FLAKE_DIR}#{host}"],
        timeout=HEAVY_TIMEOUT,
    )


@mcp.tool()
def flake_check() -> str:
    """nix flake check over the repository (evaluates all outputs). Heavy."""
    _audit("flake_check")
    return _run(
        ["nix", "flake", "check", "--no-build", str(FLAKE_DIR)],
        timeout=HEAVY_TIMEOUT,
    )


# ──────────────────────────────────────────────────────────────────────────────
# Hermes-specific read-only tools (Task 3 deliverables)
# ──────────────────────────────────────────────────────────────────────────────

@mcp.tool()
def hermes_status() -> str:
    """Current Hermes profile, active model, provider, skills count, and uptime."""
    _audit("hermes_status")
    try:
        out = subprocess.run(
            ["hermes", "status", "--json"],
            capture_output=True, text=True, timeout=10
        )
        if out.returncode == 0:
            return out.stdout.strip()
    except Exception:
        pass
    return _run(["hermes", "status"])


@mcp.tool()
def list_skills(category: str | None = None) -> str:
    """List available Hermes skills (optionally filtered by category)."""
    _audit("list_skills", category or "")
    try:
        cmd = ["hermes", "skills", "list"]
        if category:
            cmd += ["--category", category]
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        if out.returncode == 0:
            return out.stdout.strip()
    except Exception:
        pass
    return "[hermes] skills list unavailable"


@mcp.tool()
def session_summary(session_id: str | None = None, limit: int = 5) -> str:
    """Summarize recent session(s). If session_id omitted, shows the last N sessions."""
    _audit("session_summary", f"{session_id or 'latest'} n={limit}")
    try:
        cmd = ["hermes", "sessions", "summary", "--limit", str(min(max(limit, 1), 20))]
        if session_id:
            cmd += ["--session", session_id]
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
        if out.returncode == 0:
            return out.stdout.strip()
    except Exception:
        pass
    return "[hermes] session summary unavailable"


if __name__ == "__main__":
    mcp.run()  # stdio transport (default)
#!/usr/bin/env python3
"""
Oligarchy MCP — a dedicated, local, READ-ONLY Model Context Protocol server for
working on this NixOS system.

Replaces the removed OpenClaw gateway. Design goals:
  * stdio transport only — no network listener, no LAN exposure, no auth token.
  * Read-only — every tool inspects or dry-runs; none mutate the running system.
  * No remote code fetch — tools are a fixed allowlist that shells out to the
    system's own CLIs (oligarchy-ctl, oligarchy-security, hydramesh-*,
    dsp-status, ai-stack, nix, systemctl/journalctl).
  * Auditable — every tool call is appended to an audit log.

Consumed by Claude Code (via .mcp.json) and by Blipply (spawned over stdio).
"""

from __future__ import annotations

import os
import shutil
import subprocess
import time
from pathlib import Path

from mcp.server.fastmcp import FastMCP

mcp = FastMCP("oligarchy")

def _resolve_flake_dir() -> Path:
    """Explicit env wins; else the cwd if it's a flake (Claude Code sets cwd to
    the project root); else the installed-system default."""
    env = os.environ.get("OLIGARCHY_FLAKE_DIR")
    if env:
        return Path(env).resolve()
    cwd = Path.cwd()
    if (cwd / "flake.nix").is_file():
        return cwd.resolve()
    return Path("/etc/nixos")


# Flake/repo directory this server operates on (read-only).
FLAKE_DIR = _resolve_flake_dir()

# Heavy operations (dry-build / flake check) get a generous timeout; quick
# status calls a short one.
QUICK_TIMEOUT = 20
HEAVY_TIMEOUT = 900

_AUDIT_PATH = Path(
    os.environ.get("XDG_STATE_HOME", os.path.expanduser("~/.local/state"))
) / "oligarchy-mcp" / "audit.log"


def _audit(tool: str, detail: str = "") -> None:
    try:
        _AUDIT_PATH.parent.mkdir(parents=True, exist_ok=True)
        with _AUDIT_PATH.open("a") as fh:
            fh.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')}\t{tool}\t{detail}\n")
    except OSError:
        pass  # auditing must never break a read-only query


def _run(cmd: list[str], timeout: int = QUICK_TIMEOUT) -> str:
    """Run a command, returning combined stdout/stderr or a clear error string."""
    if shutil.which(cmd[0]) is None:
        return f"[unavailable] {cmd[0]} is not on PATH"
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return f"[timeout] {' '.join(cmd)} exceeded {timeout}s"
    except OSError as exc:
        return f"[error] {exc}"
    out = (proc.stdout or "") + (proc.stderr or "")
    return out.strip() or f"[exit {proc.returncode}] (no output)"


# ── Live status (wraps the existing control-center dispatcher / CLIs) ─────────

@mcp.tool()
def system_status() -> str:
    """Kernel, host, power profile, DCF and AI status (one-line summary)."""
    _audit("system_status")
    return _run(["oligarchy-ctl", "status"])


@mcp.tool()
def security_status() -> str:
    """Security posture: SSH auth mode, fail2ban, strict-egress firewall,
    ClamAV/malware-shield events, AppArmor/auditd/USBGuard, rootless docker.
    Read-only."""
    _audit("security_status")
    return _run(["oligarchy-security", "status"])


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


# ── Flake / config inspection (sandboxed to FLAKE_DIR) ────────────────────────

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


# ── Available declarative options ─────────────────────────────────────────────

@mcp.tool()
def kernel_options() -> str:
    """Available custom.kernel.variant values."""
    _audit("kernel_options")
    return "zen, xanmod, latest, cachyos-bore (cachyos-bore is opt-in/experimental)"


@mcp.tool()
def gpu_options() -> str:
    """Available custom.platform.gpu values and the matching flake targets."""
    _audit("gpu_options")
    return (
        "amd (.#nixos), intel (.#nixos-intel), "
        "nvidia-optimus (.#nixos-optimus)"
    )


# ── Heavy, still read-only: dry-build / flake check ───────────────────────────

@mcp.tool()
def dry_build(host: str = "nixos") -> str:
    """`nixos-rebuild dry-build` for a host (.#nixos / nixos-intel / nixos-optimus).

    Computes what WOULD build without activating anything. Heavy; may take minutes.
    """
    if host not in {"nixos", "nixos-intel", "nixos-optimus"}:
        return "[denied] host must be nixos | nixos-intel | nixos-optimus"
    _audit("dry_build", host)
    return _run(
        ["nixos-rebuild", "dry-build", "--flake", f"{FLAKE_DIR}#{host}"],
        timeout=HEAVY_TIMEOUT,
    )


@mcp.tool()
def flake_check() -> str:
    """`nix flake check` over the repository (evaluates all outputs). Heavy."""
    _audit("flake_check")
    return _run(
        ["nix", "flake", "check", "--no-build", str(FLAKE_DIR)],
        timeout=HEAVY_TIMEOUT,
    )


if __name__ == "__main__":
    mcp.run()  # stdio transport by default

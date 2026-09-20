#!/usr/bin/env python3
"""Finish BlueZ bonding for already-connected BLE HID gamepads only.

Security properties (load-bearing — do not "simplify"):
- Never Pair() unless GAP appearance is 0x03c4 (gamepad) AND UUID 00001812 (HID).
- Never Trust() a device that is not already Paired.
- Never Pair() keyboards (0x03c1), mice, audio. Names are ignored.
- Never un-block a Blocked device.
- This module adds no BlueZ agent of its own and does not set Discoverable.
  Note that each bluetoothctl invocation registers bluetoothctl's own default
  agent for the lifetime of that invocation, so a confirmation request raised
  during `pair` lands on a non-interactive agent -- one way a `pair` can hang
  until the timeout.
"""

from __future__ import annotations

import enum
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, List, Sequence, Tuple


class Action(enum.Enum):
    NOOP = "noop"
    PAIR = "pair"
    TRUST = "trust"


APPEARANCE_GAMEPAD = 0x03C4
HID_UUID = "00001812-0000-1000-8000-00805f9b34fb"


def _flag(info: str, key: str) -> bool:
    m = re.search(rf"^\t{re.escape(key)}:\s*(yes|no)\s*$", info, re.MULTILINE)
    if not m:
        return False
    return m.group(1) == "yes"


def _appearance(info: str) -> int | None:
    m = re.search(r"^\tAppearance:\s*0x([0-9a-fA-F]+)\b", info, re.MULTILINE)
    if not m:
        return None
    return int(m.group(1), 16)


def _has_hid_uuid(info: str) -> bool:
    return HID_UUID.lower() in info.lower()


def parse_mac(info: str) -> str | None:
    m = re.match(r"Device\s+([0-9A-Fa-f:]{17})\b", info)
    return m.group(1).upper() if m else None


def classify(info: str) -> Action:
    if _flag(info, "Blocked"):
        return Action.NOOP
    if not _flag(info, "Connected"):
        return Action.NOOP
    if _appearance(info) != APPEARANCE_GAMEPAD:
        return Action.NOOP
    if not _has_hid_uuid(info):
        return Action.NOOP
    paired = _flag(info, "Paired")
    trusted = _flag(info, "Trusted")
    if not paired:
        return Action.PAIR
    if not trusted:
        return Action.TRUST
    return Action.NOOP


def classify_all(infos: Dict[str, str]) -> Dict[str, Action]:
    return {mac: classify(text) for mac, text in infos.items()}


Cmd = Tuple[str, ...]


def plan_commands(infos: Dict[str, str]) -> List[Tuple[str, str]]:
    out: List[Tuple[str, str]] = []
    for mac, text in infos.items():
        action = classify(text)
        mac_u = mac.upper()
        if action is Action.PAIR:
            out.append(("pair", mac_u))
        elif action is Action.TRUST:
            out.append(("trust", mac_u))
    return out


def plan_reconnect(*, paired: bool, connected: bool, js_exists: bool) -> List[Cmd]:
    if paired and connected and not js_exists:
        return [("disconnect",), ("connect",)]
    return []


def reconnect_bt_args(mac: str, steps: List[Cmd]) -> List[List[str]]:
    """One bluetoothctl argv per planned step. No extra connect after disconnect."""
    return [[step[0], mac] for step in steps]


def should_trust_after_pair(info: str) -> bool:
    """Trust only if BlueZ now reports Paired=yes. rc=0 on pair is not enough."""
    return _flag(info, "Paired") and not _flag(info, "Blocked")


def hog_input_bound(mac: str, devices_text: str | None = None) -> bool:
    """True only if THIS MAC already has a js handler — not some other joystick."""
    if devices_text is None:
        try:
            devices_text = Path("/proc/bus/input/devices").read_text()
        except OSError:
            return False
    needle = f"uniq={mac.lower()}"
    for block in devices_text.split("\n\n"):
        if needle not in block.lower():
            continue
        if re.search(r"Handlers=.*\bjs\d+", block):
            return True
    return False


def _as_text(blob: object) -> str:
    """TimeoutExpired.stdout/.stderr may be bytes or None even under text=True."""
    if blob is None:
        return ""
    if isinstance(blob, (bytes, bytearray)):
        return bytes(blob).decode("utf-8", "replace")
    return str(blob)


def _run_bluetoothctl(args: Sequence[str], *, timeout: int = 20) -> subprocess.CompletedProcess[str]:
    """Never raises on timeout: a killed CLI must not kill the oneshot.

    subprocess.run() has already killed the child by the time TimeoutExpired is
    raised, so the synthetic rc=124 result is the whole story the caller needs.
    """
    try:
        return subprocess.run(
            ["bluetoothctl", *args],
            check=False,
            text=True,
            capture_output=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as e:
        return subprocess.CompletedProcess(
            args=["bluetoothctl", *args],
            returncode=124,
            stdout=_as_text(e.stdout),
            stderr=f"timed out after {timeout}s",
        )


def collect_infos() -> Dict[str, str]:
    listed = _run_bluetoothctl(["devices"])
    infos: Dict[str, str] = {}
    for line in listed.stdout.splitlines():
        m = re.match(r"Device\s+([0-9A-Fa-f:]{17})\s+", line)
        if not m:
            continue
        mac = m.group(1)
        info = _run_bluetoothctl(["info", mac])
        infos[mac.upper()] = info.stdout
    return infos


def apply_commands(cmds: List[Tuple[str, str]], *, dry_run: bool) -> None:
    for op, mac in cmds:
        print(f"hog-finish-bond: {op} {mac}")
        if dry_run:
            continue
        proc = _run_bluetoothctl([op, mac], timeout=30)
        if proc.returncode != 0:
            print(
                f"hog-finish-bond: {op} {mac} failed rc={proc.returncode}\n{proc.stderr}",
                file=sys.stderr,
            )
            if op != "pair":
                continue
            # A pair can fail or time out at the CLI while BlueZ finishes the
            # bond anyway (observed: bluetoothctl killed at 30s, the pad read
            # back Paired=yes minutes later). So always re-read info and let
            # should_trust_after_pair() -- not the exit code -- decide.
        if op == "pair":
            info = _run_bluetoothctl(["info", mac], timeout=10).stdout
            if not should_trust_after_pair(info):
                print(
                    f"hog-finish-bond: pair {mac} did not yield Paired=yes; not trusting",
                    file=sys.stderr,
                )
                continue
            trust = _run_bluetoothctl(["trust", mac], timeout=10)
            if trust.returncode != 0:
                print(f"hog-finish-bond: trust {mac} failed\n{trust.stderr}", file=sys.stderr)


def maybe_reconnect(mac: str, *, dry_run: bool) -> None:
    info = ""
    if not dry_run:
        info = _run_bluetoothctl(["info", mac]).stdout
        if not info.strip():
            # Empty means the info call failed or timed out. Treating that as
            # paired+connected would fire disconnect/connect blind.
            print(
                f"hog-finish-bond: no info for {mac}; not reconnecting",
                file=sys.stderr,
            )
            return
    paired = _flag(info, "Paired") if info else True
    connected = _flag(info, "Connected") if info else True
    steps = plan_reconnect(
        paired=paired, connected=connected, js_exists=hog_input_bound(mac)
    )
    for argv in reconnect_bt_args(mac, steps):
        print(f"hog-finish-bond: {' '.join(argv)} (HID not bound)")
        if dry_run:
            continue
        _run_bluetoothctl(argv, timeout=20)
        time.sleep(2)


def main(argv: list[str]) -> int:
    dry_run = "--dry-run" in argv
    if "-h" in argv or "--help" in argv:
        print("usage: hog_finish_bond.py [--dry-run]")
        return 0
    infos = collect_infos()
    cmds = plan_commands(infos)
    apply_commands(cmds, dry_run=dry_run)
    # Reconnect only MACs we just paired (HID often needs a new HoG session).
    for op, mac in cmds:
        if op == "pair":
            maybe_reconnect(mac, dry_run=dry_run)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

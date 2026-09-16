#!/usr/bin/env python3
"""Finish BlueZ bonding for already-connected BLE HID gamepads only.

Security properties (load-bearing — do not "simplify"):
- Never Pair() unless GAP appearance is 0x03c4 (gamepad) AND UUID 00001812 (HID).
- Never Trust() a device that is not already Paired.
- Never Pair() keyboards (0x03c1), mice, audio. Names are ignored.
- Never un-block a Blocked device.
- This module does not register a BlueZ agent and does not set Discoverable.
"""

from __future__ import annotations

import enum
import re
import sys
from typing import Dict


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


def main(argv: list[str]) -> int:
    # Filled in Task 4. Keep a stub so `python3 hog_finish_bond.py --help` exists.
    if argv[1:] in (["-h"], ["--help"]):
        print("usage: hog_finish_bond.py [--dry-run]")
        return 0
    print("hog_finish_bond: runner not wired", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))

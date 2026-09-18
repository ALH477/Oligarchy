"""Block and catalog JSON documents."""

from __future__ import annotations

import json
import socket
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from reliquary import CATALOG_SCHEMA, SCHEMA


def utcnow() -> str:
    return datetime.now(timezone.utc).replace(microsecond=0).isoformat()


def write_json(path: Path, data: dict[str, Any]) -> None:
    path.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def read_json(path: Path) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def new_block_manifest(
    *,
    block_id: str,
    origin: str,
    payload: dict[str, Any],
    par2: dict[str, Any],
    profile: str,
    notes: str = "",
) -> dict[str, Any]:
    return {
        "schema": SCHEMA,
        "id": block_id,
        "created": utcnow(),
        "source_host": socket.gethostname(),
        "origin": origin,
        "profile": profile,
        "notes": notes,
        "payload": payload,
        "par2": par2,
        "copies": [],
    }


def empty_catalog() -> dict[str, Any]:
    return {
        "schema": CATALOG_SCHEMA,
        "updated": utcnow(),
        "blocks": [],
    }


def record_copy(manifest: dict[str, Any], medium: str, location: str) -> None:
    manifest.setdefault("copies", []).append(
        {"medium": medium, "location": location, "at": utcnow()}
    )

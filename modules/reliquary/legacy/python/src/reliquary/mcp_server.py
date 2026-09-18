"""Minimal MCP 2024-11-05 stdio server. No third-party MCP SDK required.

Speaks JSON-RPC 2.0 with Content-Length framing so Claude Desktop, Cursor,
and other hosts can drive ingest / copy / verify / extract / ISO.
"""

from __future__ import annotations

import json
import sys
import traceback
from pathlib import Path
from typing import Any

from reliquary import __version__
from reliquary.config import Config
from reliquary.store import Store
from reliquary import optical, usb


TOOLS = [
    {
        "name": "reliquary_status",
        "description": "Local store path, block count, and whether USB-A / USB-B partitions are present and mounted.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "reliquary_list_blocks",
        "description": "List preservation blocks in the local Reliquary store.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
    {
        "name": "reliquary_show_block",
        "description": "Show the full manifest for one block.",
        "inputSchema": {
            "type": "object",
            "properties": {"block_id": {"type": "string"}},
            "required": ["block_id"],
        },
    },
    {
        "name": "reliquary_ingest",
        "description": "Pack a filesystem path into a tarball+checksum+PAR2 block. profile=cd sizes the block for an 80-minute CD-R; profile=usb allows larger blocks.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "path": {"type": "string"},
                "profile": {"type": "string", "enum": ["cd", "usb"], "default": "cd"},
                "notes": {"type": "string"},
                "force": {"type": "boolean", "default": False},
            },
            "required": ["path"],
        },
    },
    {
        "name": "reliquary_verify",
        "description": "Verify SHA-256/512 manifests and PAR2 for a block. Optionally repair from PAR2.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "block_id": {"type": "string"},
                "repair": {"type": "boolean", "default": False},
            },
            "required": ["block_id"],
        },
    },
    {
        "name": "reliquary_extract",
        "description": "Verify (unless skipped) and extract a block's tarball to dest.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "block_id": {"type": "string"},
                "dest": {"type": "string"},
                "verify": {"type": "boolean", "default": True},
            },
            "required": ["block_id", "dest"],
        },
    },
    {
        "name": "reliquary_push_usb",
        "description": "Copy a block onto the mounted USB data partitions (roles A, B, or AB) and refresh META catalogs.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "block_id": {"type": "string"},
                "roles": {"type": "string", "default": "AB"},
            },
            "required": ["block_id"],
        },
    },
    {
        "name": "reliquary_pull_usb",
        "description": "Copy a block from a mounted USB data partition into the local store.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "block_id": {"type": "string"},
                "role": {"type": "string", "enum": ["A", "B"], "default": "A"},
            },
            "required": ["block_id"],
        },
    },
    {
        "name": "reliquary_make_cd_iso",
        "description": "Build an ISO 9660 / Rock Ridge / Joliet image of one block, sized for a writable 80-minute CD-R.",
        "inputSchema": {
            "type": "object",
            "properties": {"block_id": {"type": "string"}},
            "required": ["block_id"],
        },
    },
    {
        "name": "reliquary_burn_cd",
        "description": "Burn an ISO to a CD writer device with xorriso. dummy=true runs a laser-off rehearsal.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "iso": {"type": "string"},
                "device": {"type": "string"},
                "dummy": {"type": "boolean", "default": False},
            },
            "required": ["iso", "device"],
        },
    },
    {
        "name": "reliquary_usb_status",
        "description": "Detailed USB-A / USB-B partition detection via lsblk labels.",
        "inputSchema": {"type": "object", "properties": {}, "additionalProperties": False},
    },
]


class Server:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        self.store = Store(cfg)

    def handle(self, msg: dict[str, Any]) -> dict[str, Any] | None:
        if "method" not in msg:
            return _error(msg.get("id"), -32600, "invalid request")
        method = msg["method"]
        mid = msg.get("id")
        params = msg.get("params") or {}
        if method.startswith("notifications/"):
            return None
        try:
            result = self.dispatch(method, params)
            return {"jsonrpc": "2.0", "id": mid, "result": result}
        except Exception as exc:  # noqa: BLE001
            return _error(mid, -32000, str(exc), traceback.format_exc())

    def dispatch(self, method: str, params: dict[str, Any]) -> Any:
        if method == "initialize":
            return {
                "protocolVersion": params.get("protocolVersion") or "2024-11-05",
                "capabilities": {"tools": {}, "resources": {}},
                "serverInfo": {"name": "reliquary", "version": __version__},
            }
        if method == "ping":
            return {}
        if method == "tools/list":
            return {"tools": TOOLS}
        if method == "tools/call":
            return self.call_tool(params.get("name"), params.get("arguments") or {})
        if method == "resources/list":
            resources = [
                {
                    "uri": f"reliquary://block/{b['id']}",
                    "name": b["id"],
                    "mimeType": "application/json",
                }
                for b in self.store.list_blocks()
            ]
            return {"resources": resources}
        if method == "resources/read":
            uri = params.get("uri", "")
            prefix = "reliquary://block/"
            if uri.startswith(prefix):
                man = self.store.load_manifest(uri[len(prefix) :])
                return {
                    "contents": [
                        {
                            "uri": uri,
                            "mimeType": "application/json",
                            "text": json.dumps(man, indent=2),
                        }
                    ]
                }
            raise ValueError(f"unknown resource {uri}")
        raise ValueError(f"unknown method {method}")

    def call_tool(self, name: str, args: dict[str, Any]) -> dict[str, Any]:
        def ok(payload: Any) -> dict[str, Any]:
            text = payload if isinstance(payload, str) else json.dumps(payload, indent=2, default=str)
            return {"content": [{"type": "text", "text": text}]}

        if name == "reliquary_status":
            return ok(
                {
                    "store_root": str(self.cfg.store_root),
                    "blocks": len(self.store.list_blocks()),
                    "usb": usb.volume_status(self.cfg),
                }
            )
        if name == "reliquary_list_blocks":
            return ok(
                [
                    {
                        "id": m["id"],
                        "created": m.get("created"),
                        "profile": m.get("profile"),
                        "bytes": m.get("payload", {}).get("bytes"),
                        "origin": m.get("origin"),
                    }
                    for m in self.store.list_blocks()
                ]
            )
        if name == "reliquary_show_block":
            return ok(self.store.load_manifest(args["block_id"]))
        if name == "reliquary_ingest":
            return ok(
                self.store.ingest(
                    Path(args["path"]),
                    profile=args.get("profile") or "cd",
                    notes=args.get("notes") or "",
                    force=bool(args.get("force")),
                )
            )
        if name == "reliquary_verify":
            return ok(self.store.verify(args["block_id"], repair=bool(args.get("repair"))))
        if name == "reliquary_extract":
            dest = self.store.extract(
                args["block_id"],
                Path(args["dest"]),
                verify_first=args.get("verify", True),
            )
            return ok({"extracted_to": str(dest)})
        if name == "reliquary_push_usb":
            return ok(usb.push_block(self.cfg, self.store, args["block_id"], roles=args.get("roles") or "AB"))
        if name == "reliquary_pull_usb":
            dest = usb.pull_block(self.cfg, self.store, args["block_id"], args.get("role") or "A")
            return ok({"pulled_to": str(dest)})
        if name == "reliquary_make_cd_iso":
            iso = optical.make_iso(self.cfg, self.store, args["block_id"])
            return ok(optical.iso_info(iso))
        if name == "reliquary_burn_cd":
            return ok(optical.burn_iso(Path(args["iso"]), Path(args["device"]), dummy=bool(args.get("dummy"))))
        if name == "reliquary_usb_status":
            return ok(usb.volume_status(self.cfg))
        raise ValueError(f"unknown tool {name}")


def _error(mid, code: int, message: str, data: str | None = None) -> dict[str, Any]:
    err: dict[str, Any] = {"code": code, "message": message}
    if data:
        err["data"] = data
    return {"jsonrpc": "2.0", "id": mid, "error": err}


def _read_message() -> dict[str, Any] | None:
    headers: dict[str, str] = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        if line in (b"\r\n", b"\n"):
            break
        decoded = line.decode("utf-8")
        key, _, value = decoded.partition(":")
        headers[key.strip().lower()] = value.strip()
    length = int(headers.get("content-length") or "0")
    if length <= 0:
        return None
    body = sys.stdin.buffer.read(length)
    return json.loads(body.decode("utf-8"))


def _write_message(msg: dict[str, Any]) -> None:
    raw = json.dumps(msg).encode("utf-8")
    sys.stdout.buffer.write(f"Content-Length: {len(raw)}\r\n\r\n".encode("ascii"))
    sys.stdout.buffer.write(raw)
    sys.stdout.buffer.flush()


def run_stdio(cfg: Config) -> int:
    server = Server(cfg)
    while True:
        try:
            msg = _read_message()
        except Exception:
            return 1
        if msg is None:
            return 0
        reply = server.handle(msg)
        if reply is not None:
            _write_message(reply)

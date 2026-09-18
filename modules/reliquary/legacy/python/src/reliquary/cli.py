"""Command-line front end. The TUI and MCP server are subcommands."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from reliquary import __version__
from reliquary.config import load_config
from reliquary.store import Store, StoreError
from reliquary import optical, usb
from reliquary.usb import WIPE_PHRASE


def _out(data) -> int:
    if isinstance(data, (dict, list)):
        sys.stdout.write(json.dumps(data, indent=2, default=str) + "\n")
    else:
        sys.stdout.write(str(data).rstrip() + "\n")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="reliquary",
        description="Preserve a tree onto duplicated USB partitions and CD-R data blocks.",
    )
    parser.add_argument("--version", action="version", version=f"reliquary {__version__}")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("status", help="local store + USB presence")
    p.set_defaults(fn=cmd_status)

    p = sub.add_parser("ingest", help="pack a path into a verified preservation block")
    p.add_argument("path", type=Path)
    p.add_argument("--profile", choices=("cd", "usb"), default="cd")
    p.add_argument("--notes", default="")
    p.add_argument("--force", action="store_true")
    p.set_defaults(fn=cmd_ingest)

    p = sub.add_parser("list", help="list blocks in the local store")
    p.set_defaults(fn=cmd_list)

    p = sub.add_parser("show", help="print one block manifest")
    p.add_argument("block_id")
    p.set_defaults(fn=cmd_show)

    p = sub.add_parser("verify", help="checksum + PAR2 verify a block")
    p.add_argument("block_id")
    p.add_argument("--repair", action="store_true")
    p.set_defaults(fn=cmd_verify)

    p = sub.add_parser("extract", help="unpack a block after verifying it")
    p.add_argument("block_id")
    p.add_argument("dest", type=Path)
    p.add_argument("--no-verify", action="store_true")
    p.set_defaults(fn=cmd_extract)

    p = sub.add_parser("push", help="copy a block onto mounted USB data partitions")
    p.add_argument("block_id")
    p.add_argument("--roles", default="AB", help="A, B, or AB")
    p.set_defaults(fn=cmd_push)

    p = sub.add_parser("pull", help="copy a block off a mounted USB into the local store")
    p.add_argument("block_id")
    p.add_argument("--role", default="A", choices=("A", "B"))
    p.set_defaults(fn=cmd_pull)

    p = sub.add_parser("iso", help="build a CD-R ISO of one block")
    p.add_argument("block_id")
    p.set_defaults(fn=cmd_iso)

    p = sub.add_parser("burn", help="burn an ISO to a CD writer")
    p.add_argument("iso", type=Path)
    p.add_argument("device", type=Path)
    p.add_argument("--dummy", action="store_true", help="laser off rehearsal")
    p.set_defaults(fn=cmd_burn)

    p = sub.add_parser("usb", help="USB layout helpers")
    us = p.add_subparsers(dest="usb_cmd", required=True)
    q = us.add_parser("status")
    q.set_defaults(fn=cmd_usb_status)
    q = us.add_parser("format", help="GPT + FAT32 META + ext4 DATA (DESTROYS THE DISK)")
    q.add_argument("device", type=Path)
    q.add_argument("--role", required=True, choices=("A", "B"))
    q.add_argument("--confirm", required=True)
    q.set_defaults(fn=cmd_usb_format)
    q = us.add_parser("seed", help="write catalog + README onto mounted META partitions")
    q.set_defaults(fn=cmd_usb_seed)

    p = sub.add_parser("tui", help="interactive preservation console")
    p.set_defaults(fn=cmd_tui)

    p = sub.add_parser("mcp", help="Model Context Protocol server (stdio)")
    p.set_defaults(fn=cmd_mcp)

    args = parser.parse_args(argv)
    try:
        return args.fn(args)
    except (StoreError, OSError) as exc:
        sys.stderr.write(f"reliquary: {exc}\n")
        return 1


def _store(_args) -> Store:
    return Store(load_config())


def cmd_status(args) -> int:
    store = _store(args)
    cfg = store.cfg
    blocks = store.list_blocks()
    return _out(
        {
            "version": __version__,
            "store_root": str(cfg.store_root),
            "blocks": len(blocks),
            "usb": usb.volume_status(cfg),
        }
    )


def cmd_ingest(args) -> int:
    man = _store(args).ingest(args.path, profile=args.profile, notes=args.notes, force=args.force)
    return _out(man)


def cmd_list(args) -> int:
    rows = []
    for man in _store(args).list_blocks():
        rows.append(
            {
                "id": man["id"],
                "created": man.get("created"),
                "profile": man.get("profile"),
                "bytes": man.get("payload", {}).get("bytes"),
                "origin": man.get("origin"),
                "copies": len(man.get("copies") or []),
            }
        )
    return _out(rows)


def cmd_show(args) -> int:
    return _out(_store(args).load_manifest(args.block_id))


def cmd_verify(args) -> int:
    result = _store(args).verify(args.block_id, repair=args.repair)
    rc = 0 if result["ok"] else 2
    _out(result)
    return rc


def cmd_extract(args) -> int:
    dest = _store(args).extract(args.block_id, args.dest, verify_first=not args.no_verify)
    return _out({"extracted_to": str(dest)})


def cmd_push(args) -> int:
    store = _store(args)
    return _out(usb.push_block(store.cfg, store, args.block_id, roles=args.roles))


def cmd_pull(args) -> int:
    store = _store(args)
    dest = usb.pull_block(store.cfg, store, args.block_id, args.role)
    return _out({"pulled_to": str(dest)})


def cmd_iso(args) -> int:
    store = _store(args)
    iso = optical.make_iso(store.cfg, store, args.block_id)
    return _out(optical.iso_info(iso))


def cmd_burn(args) -> int:
    return _out(optical.burn_iso(args.iso, args.device, dummy=args.dummy))


def cmd_usb_status(args) -> int:
    return _out(usb.volume_status(load_config()))


def cmd_usb_format(args) -> int:
    cfg = load_config()
    role = cfg.usb_a if args.role == "A" else cfg.usb_b
    if args.confirm != WIPE_PHRASE:
        raise StoreError(f"pass --confirm {WIPE_PHRASE}")
    return _out(usb.format_usb(cfg, args.device, role, confirm=args.confirm))


def cmd_usb_seed(args) -> int:
    store = _store(args)
    written = usb.seed_meta(store.cfg, store)
    return _out({"seeded": written})


def cmd_tui(args) -> int:
    from reliquary.tui import run_tui

    return run_tui(load_config())


def cmd_mcp(args) -> int:
    from reliquary.mcp_server import run_stdio

    return run_stdio(load_config())

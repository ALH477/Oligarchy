"""Detect, format, mount-aware copy for the two 256 GB USB mirrors."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from reliquary.config import Config, USB_META_MIB, UsbRole
from reliquary.store import Store, StoreError
from reliquary.util import require_tool, run


WIPE_PHRASE = "WIPE-THIS-USB"


def lsblk() -> dict[str, Any]:
    require_tool("lsblk")
    proc = run(
        [
            "lsblk",
            "-J",
            "-b",
            "-o",
            "NAME,PATH,LABEL,SIZE,FSTYPE,MOUNTPOINT,TRAN,MODEL,SERIAL,TYPE,PARTLABEL,UUID",
        ],
        check=True,
    )
    return json.loads(proc.stdout or "{}")


def iter_nodes(tree: dict[str, Any] | None = None):
    tree = tree or lsblk()
    for blk in tree.get("blockdevices", []):
        yield from _walk(blk)


def _walk(node: dict[str, Any]):
    yield node
    for child in node.get("children") or []:
        yield from _walk(child)


def find_by_label(label: str) -> dict[str, Any] | None:
    for node in iter_nodes():
        if node.get("label") == label:
            return node
    return None


def volume_status(cfg: Config) -> dict[str, Any]:
    roles = {}
    for role in (cfg.usb_a, cfg.usb_b):
        meta = find_by_label(role.meta_label)
        data = find_by_label(role.data_label)
        roles[role.role] = {
            "role": role.role,
            "disk_label": role.disk_label,
            "meta": _brief(meta, role.meta_label),
            "data": _brief(data, role.data_label),
            "present": bool(meta or data),
            "ready": bool(
                data
                and data.get("mountpoint")
                and meta
                and meta.get("mountpoint")
            ),
        }
    return roles


def _brief(node: dict[str, Any] | None, label: str) -> dict[str, Any]:
    if not node:
        return {"label": label, "present": False}
    return {
        "label": label,
        "present": True,
        "path": node.get("path") or f"/dev/{node.get('name')}",
        "size": int(node.get("size") or 0),
        "fstype": node.get("fstype"),
        "mountpoint": node.get("mountpoint"),
        "uuid": node.get("uuid"),
    }


def format_usb(cfg: Config, device: Path, role: UsbRole, *, confirm: str) -> dict[str, Any]:
    """Partition a whole USB disk into META (FAT32) + DATA (ext4).

    Destroys every partition on `device`. `confirm` must equal WIPE_PHRASE.
    """
    if confirm != WIPE_PHRASE:
        raise StoreError(
            f"refusing to format {device}: pass --confirm {WIPE_PHRASE} "
            "after you have triple-checked the device node."
        )
    device = Path(device)
    if not device.exists():
        raise StoreError(f"no such device: {device}")

    # Refuse if any partition is mounted.
    tree = lsblk()
    for node in iter_nodes(tree):
        path = node.get("path") or f"/dev/{node.get('name')}"
        if path == str(device) or path.startswith(str(device)):
            if node.get("mountpoint"):
                raise StoreError(f"{path} is mounted at {node['mountpoint']}; unmount first")

    sgdisk = require_tool("sgdisk")
    mkfs_vfat = require_tool("mkfs.vfat")
    mkfs_ext4 = require_tool("mkfs.ext4")

    run([sgdisk, "--zap-all", str(device)], check=True)
    run([sgdisk, "-og", str(device)], check=True)
    run(
        [
            sgdisk,
            "-n",
            f"1:0:+{USB_META_MIB}M",
            "-t",
            "1:0700",
            "-c",
            f"1:{role.meta_label}",
            str(device),
        ],
        check=True,
    )
    run(
        [
            sgdisk,
            "-n",
            "2:0:0",
            "-t",
            "2:8300",
            "-c",
            f"2:{role.data_label}",
            str(device),
        ],
        check=True,
    )
    run(["partprobe", str(device)], check=False)

    p1, p2 = _partition_nodes(device)
    run([mkfs_vfat, "-F", "32", "-n", role.meta_label[:11], p1], check=True)
    run(
        [
            mkfs_ext4,
            "-F",
            "-L",
            role.data_label,
            "-m",
            "1",
            p2,
        ],
        check=True,
    )
    return {
        "device": str(device),
        "role": role.role,
        "meta": {"path": p1, "label": role.meta_label, "fstype": "vfat", "size_mib": USB_META_MIB},
        "data": {"path": p2, "label": role.data_label, "fstype": "ext4"},
        "note": "Mount by label, then run: reliquary usb seed && reliquary push --all",
    }


def _partition_nodes(device: Path) -> tuple[str, str]:
    name = device.name
    # NVMe / mmc style vs sdX style.
    if name.startswith(("nvme", "mmcblk", "loop")):
        return f"{device}p1", f"{device}p2"
    return f"{device}1", f"{device}2"


def mountpoint_for(label: str) -> Path:
    node = find_by_label(label)
    if not node or not node.get("mountpoint"):
        raise StoreError(
            f"partition labelled {label} is not mounted. "
            f"e.g. mkdir -p /mnt/{label} && mount -L {label} /mnt/{label}"
        )
    return Path(node["mountpoint"])


def seed_meta(cfg: Config, store: Store) -> list[str]:
    """Write catalog + README onto every mounted META partition."""
    written: list[str] = []
    for role in (cfg.usb_a, cfg.usb_b):
        node = find_by_label(role.meta_label)
        if not node or not node.get("mountpoint"):
            continue
        root = Path(node["mountpoint"])
        readme = root / "README-RELIQUARY.txt"
        readme.write_text(_meta_readme(cfg, role), encoding="utf-8")
        catalog = store.catalog()
        (root / "catalog.json").write_text(
            __import__("json").dumps(catalog, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        written.append(str(root))
    return written


def push_block(cfg: Config, store: Store, block_id: str, *, roles: str = "AB") -> dict[str, Any]:
    results = {}
    for role in (cfg.usb_a, cfg.usb_b):
        if role.role not in roles:
            continue
        node = find_by_label(role.data_label)
        if not node or not node.get("mountpoint"):
            results[role.role] = {"ok": False, "error": f"{role.data_label} not mounted"}
            continue
        dest = Path(node["mountpoint"]) / "blocks"
        path = store.copy_block(block_id, dest, medium=f"usb-{role.role}")
        results[role.role] = {"ok": True, "path": str(path)}
    seed_meta(cfg, store)
    return results


def pull_block(cfg: Config, store: Store, block_id: str, role_name: str = "A") -> Path:
    role = cfg.usb_a if role_name == "A" else cfg.usb_b
    root = mountpoint_for(role.data_label)
    src = root / "blocks" / block_id
    if not src.exists():
        raise StoreError(f"{block_id} not on USB {role.role} ({src})")
    dest = store.block_dir(block_id)
    if dest.exists():
        raise StoreError(f"{block_id} already in local store; verify instead")
    import shutil

    shutil.copytree(src, dest)
    return dest


def _meta_readme(cfg: Config, role: UsbRole) -> str:
    return f"""RELIQUARY USB {role.role}
====================

This stick is one half of a duplicated pair.

  Disk GPT label : {role.disk_label}
  This partition : {role.meta_label}  (FAT32 catalog)
  Data partition : {role.data_label}  (ext4 blocks)

Each block under the data partition is a self-contained preservation
unit:

  manifest.json     identity, origin, hashes
  payload.tar.zst   the files
  SHA256SUMS / SHA512SUMS
  payload.tar.zst.par2 + recovery volumes

Verify a block without Reliquary installed:

  sha256sum -c SHA256SUMS
  par2 verify payload.tar.zst.par2

Extract:

  tar -xf payload.tar.zst

The sibling stick (role {'B' if role.role == 'A' else 'A'}) is an identical
copy. Prefer verifying both after any write. CD-R images for the same
blocks live in the local store's iso/ directory and can be burned with
xorriso / wodim / cdrecord.
"""

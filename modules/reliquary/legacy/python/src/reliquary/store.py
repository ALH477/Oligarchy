"""Local staging store: ingest, list, verify, extract."""

from __future__ import annotations

import shutil
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from reliquary.config import Config
from reliquary import archive, hashing, manifest, parity


class StoreError(RuntimeError):
    pass


def _date_prefix() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%d")


def make_block_id(payload: Path) -> str:
    digest = hashing.hash_file(payload)["sha256"][:16]
    return f"{_date_prefix()}-{digest}"


class Store:
    def __init__(self, cfg: Config):
        self.cfg = cfg
        cfg.ensure_dirs()
        if not cfg.catalog_path.exists():
            manifest.write_json(cfg.catalog_path, manifest.empty_catalog())

    def catalog(self) -> dict[str, Any]:
        return manifest.read_json(self.cfg.catalog_path)

    def _save_catalog(self, cat: dict[str, Any]) -> None:
        cat["updated"] = manifest.utcnow()
        manifest.write_json(self.cfg.catalog_path, cat)

    def block_dir(self, block_id: str) -> Path:
        return self.cfg.blocks / block_id

    def load_manifest(self, block_id: str) -> dict[str, Any]:
        path = self.block_dir(block_id) / "manifest.json"
        if not path.exists():
            raise StoreError(f"unknown block {block_id}")
        return manifest.read_json(path)

    def list_blocks(self) -> list[dict[str, Any]]:
        rows = []
        for child in sorted(self.cfg.blocks.iterdir()) if self.cfg.blocks.exists() else []:
            man = child / "manifest.json"
            if man.exists():
                rows.append(manifest.read_json(man))
        return rows

    def ingest(
        self,
        source: Path,
        *,
        profile: str = "cd",
        notes: str = "",
        force: bool = False,
    ) -> dict[str, Any]:
        source = source.expanduser().resolve()
        if not source.exists():
            raise StoreError(f"source does not exist: {source}")

        raw = archive.tree_bytes(source)
        if profile == "cd" and raw > self.cfg.cd_payload_bytes * 4:
            # Uncompressed source is huge; compressed size is only known
            # after packing. We still pack, then refuse to keep if the
            # finished payload will not fit a CD with PAR2.
            pass

        work = self.cfg.work_root / "ingest"
        if work.exists():
            shutil.rmtree(work)
        work.mkdir(parents=True)

        payload = work / "payload.tar.zst"
        packed = archive.pack_tree(source, payload, zstd_level=self.cfg.zstd_level)
        digests = hashing.hash_file(payload)
        packed.update(digests)

        if profile == "cd":
            # payload + ~20% PAR2 + ~2 MiB manifests must fit the disc.
            budget = int(self.cfg.cd_capacity_bytes * 0.92)
            expected = int(packed["bytes"] * (1 + self.cfg.par2_redundancy / 100) + 2 * 1024 * 1024)
            if expected > budget and not force:
                shutil.rmtree(work)
                raise StoreError(
                    f"packed payload {packed['bytes']} B plus {self.cfg.par2_redundancy}% PAR2 "
                    f"will not fit an 80-minute CD-R (~{budget} B usable). "
                    "Split the source, use --profile usb, or pass --force."
                )

        block_id = make_block_id(payload)
        dest = self.block_dir(block_id)
        if dest.exists():
            shutil.rmtree(work)
            return self.load_manifest(block_id)

        dest.mkdir(parents=True)
        shutil.move(str(payload), dest / "payload.tar.zst")
        payload = dest / "payload.tar.zst"

        par = parity.create_par2(
            payload,
            redundancy=self.cfg.par2_redundancy,
            volumes=self.cfg.par2_volumes,
        )
        hashing.write_sum_files(
            dest,
            [payload, *sorted(dest.glob("*.par2"))],
        )
        # Re-write sums after PAR2 so the index itself is covered? PAR2
        # files are listed above. Manifest is written last and hashed into
        # a sidecar so the document can be edited when copies are recorded.
        man = manifest.new_block_manifest(
            block_id=block_id,
            origin=str(source),
            payload=packed,
            par2=par,
            profile=profile,
            notes=notes,
        )
        manifest.write_json(dest / "manifest.json", man)
        hashing.write_sum_files(
            dest,
            [p for p in dest.iterdir() if p.is_file() and p.name not in {"SHA256SUMS", "SHA512SUMS"}],
        )

        cat = self.catalog()
        cat["blocks"] = [b for b in cat.get("blocks", []) if b.get("id") != block_id]
        cat["blocks"].append(
            {
                "id": block_id,
                "created": man["created"],
                "origin": man["origin"],
                "profile": profile,
                "payload_bytes": packed["bytes"],
                "sha256": packed["sha256"],
            }
        )
        self._save_catalog(cat)
        shutil.rmtree(work, ignore_errors=True)
        return man

    def verify(self, block_id: str, *, repair: bool = False) -> dict[str, Any]:
        dest = self.block_dir(block_id)
        if not dest.exists():
            raise StoreError(f"unknown block {block_id}")
        problems = hashing.verify_sum_file(dest, "SHA256SUMS")
        problems += hashing.verify_sum_file(dest, "SHA512SUMS")
        index = dest / "payload.tar.zst.par2"
        par = {"ok": False, "output": "missing PAR2 index"}
        if index.exists():
            par = parity.verify_par2(index)
            if not par["ok"] and repair:
                par = parity.repair_par2(index)
                if par["ok"]:
                    par = parity.verify_par2(index)
        ok = not problems and par.get("ok")
        return {"id": block_id, "ok": ok, "checksum_problems": problems, "par2": par}

    def extract(self, block_id: str, dest: Path, *, verify_first: bool = True) -> Path:
        if verify_first:
            result = self.verify(block_id)
            if not result["ok"]:
                raise StoreError(f"block {block_id} failed verification: {result}")
        dest = dest.expanduser().resolve()
        dest.mkdir(parents=True, exist_ok=True)
        archive.extract_payload(self.block_dir(block_id) / "payload.tar.zst", dest)
        return dest

    def copy_block(self, block_id: str, dest_dir: Path, medium: str) -> Path:
        src = self.block_dir(block_id)
        if not src.exists():
            raise StoreError(f"unknown block {block_id}")
        dest_dir = dest_dir.expanduser().resolve()
        dest_dir.mkdir(parents=True, exist_ok=True)
        target = dest_dir / block_id
        if target.exists():
            shutil.rmtree(target)
        shutil.copytree(src, target)
        man = manifest.read_json(target / "manifest.json")
        manifest.record_copy(man, medium, str(target))
        manifest.write_json(target / "manifest.json", man)
        # Also stamp the local original.
        local = manifest.read_json(src / "manifest.json")
        manifest.record_copy(local, medium, str(target))
        manifest.write_json(src / "manifest.json", local)
        return target

    def forget(self, block_id: str, *, yes: bool = False) -> None:
        if not yes:
            raise StoreError("refusing to delete without yes=True")
        dest = self.block_dir(block_id)
        if dest.exists():
            shutil.rmtree(dest)
        cat = self.catalog()
        cat["blocks"] = [b for b in cat.get("blocks", []) if b.get("id") != block_id]
        self._save_catalog(cat)

"""Paths, media geometry, and default policy."""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from pathlib import Path


# 80-minute CD-R: 80 * 60 * 75 * 2048 bytes
CD_R_80_BYTES = 80 * 60 * 75 * 2048  # 737_280_000

# Leave room for ISO 9660 + Rock Ridge + Joliet + El Torito-less overhead,
# manifests, checksum files, and 20% PAR2 of the payload.
DEFAULT_CD_PAYLOAD_BYTES = 520 * 1024 * 1024

# Target flash geometry for a "256 GB" stick (usable capacity varies).
USB_NOMINAL_BYTES = 256 * 1000 * 1000 * 1000
USB_META_MIB = 2048  # 2 GiB FAT32 catalog partition


@dataclass
class UsbRole:
    role: str  # "A" or "B"
    meta_label: str
    data_label: str
    disk_label: str


@dataclass
class Config:
    store_root: Path
    work_root: Path
    par2_redundancy: int = 20
    par2_volumes: int = 4
    zstd_level: int = 19
    cd_capacity_bytes: int = CD_R_80_BYTES
    cd_payload_bytes: int = DEFAULT_CD_PAYLOAD_BYTES
    usb_a: UsbRole = field(
        default_factory=lambda: UsbRole("A", "RLQ-META-A", "RLQ-DATA-A", "RELIQUARY-A")
    )
    usb_b: UsbRole = field(
        default_factory=lambda: UsbRole("B", "RLQ-META-B", "RLQ-DATA-B", "RELIQUARY-B")
    )

    @property
    def staging(self) -> Path:
        return self.store_root / "staging"

    @property
    def blocks(self) -> Path:
        return self.store_root / "blocks"

    @property
    def catalog_path(self) -> Path:
        return self.store_root / "catalog.json"

    @property
    def iso_root(self) -> Path:
        return self.store_root / "iso"

    def ensure_dirs(self) -> None:
        for p in (self.store_root, self.work_root, self.staging, self.blocks, self.iso_root):
            p.mkdir(parents=True, exist_ok=True)


def default_store_root() -> Path:
    env = os.environ.get("RELIQUARY_STORE")
    if env:
        return Path(env).expanduser()
    xdg = os.environ.get("XDG_DATA_HOME")
    if xdg:
        return Path(xdg) / "reliquary"
    return Path.home() / ".local" / "share" / "reliquary"


def load_config() -> Config:
    store = default_store_root()
    work = Path(os.environ.get("RELIQUARY_WORK", store / "work"))
    cfg = Config(store_root=store, work_root=work)
    red = os.environ.get("RELIQUARY_PAR2_REDUNDANCY")
    if red:
        cfg.par2_redundancy = int(red)
    cfg.ensure_dirs()
    return cfg

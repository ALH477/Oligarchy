import json
import socket
from pathlib import Path

from reliquary.manifest import empty_catalog, new_block_manifest, record_copy, write_json, read_json


def test_new_block_manifest_schema(tmp_path: Path):
    man = new_block_manifest(
        block_id="20260915-deadbeefdeadbeef",
        origin="/tmp/src",
        payload={"file": "payload.tar.zst", "bytes": 12, "sha256": "ab"},
        par2={"redundancy_percent": 20},
        profile="cd",
    )
    assert man["schema"] == "reliquary.block/v1"
    assert man["id"].startswith("20260915-")
    assert man["source_host"] == socket.gethostname()
    record_copy(man, "usb-A", "/mnt/x")
    assert man["copies"][0]["medium"] == "usb-A"
    dest = tmp_path / "manifest.json"
    write_json(dest, man)
    assert read_json(dest)["id"] == man["id"]


def test_empty_catalog():
    cat = empty_catalog()
    assert cat["schema"] == "reliquary.catalog/v1"
    assert cat["blocks"] == []
    json.dumps(cat)

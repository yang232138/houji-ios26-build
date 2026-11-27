#!/usr/bin/env python3
"""Transport the experimental volume identity without exposing it in Actions logs."""
import argparse
import base64
import json
import os
from pathlib import Path

from cryptography.hazmat.primitives.ciphers.aead import AESGCM

PURPOSE = b"houji-23g90-native-volume-v1"
FIELDS = (
    "first_lba", "end_lba_exclusive", "block_bytes", "blocks",
    "image_bytes", "volume_id", "image_sha256",
)


def seal(record_path, key_path):
    key = AESGCM(key_path.read_bytes())
    record = json.loads(record_path.read_text())
    nonce = os.urandom(12)
    data = json.dumps({field: record[field] for field in FIELDS}, separators=(",", ":"))
    return base64.urlsafe_b64encode(nonce + key.encrypt(nonce, data.encode(), PURPOSE)).decode()


def unseal(output):
    key = AESGCM(bytes.fromhex(os.environ["HOUJI_ARTIFACT_KEY"]))
    sealed = base64.b64decode(os.environ["HOUJI_NATIVE_VOLUME_SEALED"], altchars=b"-_", validate=True)
    data = key.decrypt(sealed[:12], sealed[12:], PURPOSE)
    record = json.loads(data)
    volume_id = bytes.fromhex(record["volume_id"])
    digest = bytes.fromhex(record["image_sha256"])
    if set(record) != set(FIELDS) or len(volume_id) != 8 or len(digest) != 32:
        raise ValueError("Invalid authenticated volume identity")
    id_bytes = ", ".join(f"0x{value:02x}" for value in volume_id)
    for value in (volume_id.hex(), id_bytes, digest.hex()):
        print(f"::add-mask::{value}", flush=True)
    output.write_bytes(data)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    unseal(parser.parse_args().output)

#!/usr/bin/env python3
"""Record the identity of the existing raw houji HFSX image without writing it."""
import argparse
import hashlib
import json
from pathlib import Path
import struct

BLOCK_SIZE = 4096
FIRST_LBA = 2260480
BLOCKS = 12 * 1024**3 // BLOCK_SIZE


def identity(header):
    signature, version = struct.unpack_from(">2sH", header)
    block_size, blocks = struct.unpack_from(">II", header, 40)
    if (signature, version, block_size, blocks) != (b"HX", 5, BLOCK_SIZE, BLOCKS):
        raise ValueError("HFSX signature/version/geometry differs")
    volume_id = header[104:112]
    if not any(volume_id):
        raise ValueError("HFSX volume ID is zero")
    return volume_id.hex()


def render_header(record):
    volume_id = bytes.fromhex(record["volume_id"])
    if len(volume_id) != 8 or not any(volume_id):
        raise ValueError("Invalid volume ID")
    digest = bytes.fromhex(record["image_sha256"])
    if len(digest) != 32:
        raise ValueError("Invalid image SHA256")
    if not (
        record["first_lba"] == FIRST_LBA
        and record["end_lba_exclusive"] == FIRST_LBA + BLOCKS
        and record["block_bytes"] == BLOCK_SIZE
        and record["blocks"] == BLOCKS
        and record["image_bytes"] == BLOCKS * BLOCK_SIZE
    ):
        raise ValueError("Wrong houji LUN0 window")
    values = ", ".join(f"0x{value:02x}" for value in volume_id)
    return (
        "// Generated from the read-only experimental HFSX source image.\n"
        f"// Image SHA256: {digest.hex()}\n"
        f"#define HOUJI_EXPERIMENT_IMAGE_SHA \"{digest.hex()}\"\n"
        f"#define HOUJI_EXPERIMENT_ID_BYTES {{{values}}}\n"
        f"#define HOUJI_EXPERIMENT_FIRST_LBA {FIRST_LBA}U\n"
        f"#define HOUJI_EXPERIMENT_BLOCKS {BLOCKS}U\n"
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--image", type=Path)
    source.add_argument("--from-record", type=Path)
    parser.add_argument("--record", type=Path)
    parser.add_argument("--header", required=True, type=Path)
    args = parser.parse_args()
    if args.from_record:
        record = json.loads(args.from_record.read_text())
        args.header.write_text(render_header(record), encoding="ascii", newline="\n")
        return
    if not args.record:
        parser.error("--image requires --record")
    before = args.image.stat()
    if before.st_size != BLOCKS * BLOCK_SIZE:
        raise ValueError("Expected a raw 12 GiB image")
    with args.image.open("rb") as image:
        image.seek(1024)
        primary = image.read(512)
        image.seek(-1024, 2)
        alternate = image.read(512)
        volume_id = identity(primary)
        if identity(alternate) != volume_id:
            raise ValueError("Primary and alternate HFSX identities differ")
        image.seek(0)
        digest = hashlib.file_digest(image, "sha256").hexdigest()
    after = args.image.stat()
    if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
        raise ValueError("HFSX image changed during verification")
    record = {
        "image": str(args.image.resolve()),
        "image_bytes": before.st_size,
        "image_sha256": digest,
        "signature": "HX",
        "version": 5,
        "block_bytes": BLOCK_SIZE,
        "blocks": BLOCKS,
        "lun": 0,
        "first_lba": FIRST_LBA,
        "end_lba_exclusive": FIRST_LBA + BLOCKS,
        "primary_header_offset": 1024,
        "alternate_header_offset": before.st_size - 1024,
        "primary_header_sha256": hashlib.sha256(primary).hexdigest(),
        "alternate_header_sha256": hashlib.sha256(alternate).hexdigest(),
        "volume_id": volume_id,
    }
    args.header.write_text(render_header(record), encoding="ascii", newline="\n")
    args.record.write_text(json.dumps(record, indent=2) + "\n", encoding="ascii")
    print(json.dumps(record, indent=2))


if __name__ == "__main__":
    main()

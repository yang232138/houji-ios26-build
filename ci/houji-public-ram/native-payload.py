#!/usr/bin/env python3
"""Build or inspect the native-root FAT payload using the actual linked Mach-O."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import tomllib
import zlib

FAT_LABEL = b"HOUJIESP   FAT32   "
FAT_BYTES = 64 * 1024**2
CONFIG = "EFI/UniXNU/unixnu.toml"
FILES = ("Payloads/kernel.macho", "Payloads/kernel.macho.adt", "Drivers/DarwinBoot.efi")
NATIVE_MARKER = b"HOUJI ROOT: both HFSX headers matched, image "
REFUSAL = b"offline native root: UFS ownership and SID 0x60 DMA proof missing"
BOOT_ARGS = "-v serial=0 debug=0x14e keepsyms=1 cpus=1 rd=md0 houji_native_root=1 sweetiolog=-"
NATIVE_CONFIG = f"""version = 1
[boot]
default = "xnu"
timeout = 3
on_return = "reset"
[[driver]]
path = "/Drivers/DarwinBoot.efi"
connect = true
[[entry]]
id = "xnu"
title = "Houji iOS 26 Native Root (offline)"
type = "xnu"
path = "/Payloads/kernel.macho"
args = "{BOOT_ARGS}"
"""


def sha(data):
    return hashlib.sha256(data).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def inspect_kernel(path, volume=None):
    data = path.read_bytes()
    magic, cpu, subtype = struct.unpack_from("<III", data)
    require((magic, cpu, subtype & 0xFFFFFF) == (0xFEEDFACF, 0x100000C, 2), "Expected an arm64e Mach-O")
    nm = ["llvm-nm", "--defined-only", "-j"] if shutil.which("llvm-nm") else ["xcrun", "nm", "-U", "-j"]
    names = subprocess.check_output([*nm, str(path)], text=True).splitlines()
    evidence = {
        "sha256": sha(data),
        "has_root_attach_symbol": "_houji_ufs_root_attach" in names,
        "has_native_md_symbol": "_mdevadd_ops" in names,
        "has_hfs_mount_and_validation_symbols": "_hfs_MountHFSPlusVolume" in names and "_hfs_ValidateHFSPlusVolumeHeader" in names,
        "has_native_registration_code": b"HOUJI ROOT: md0 is native UFS LUN0" in data,
        "has_experiment_binding": NATIVE_MARKER in data,
        "has_offline_refusal": REFUSAL in data,
    }
    if volume:
        require(all(evidence[key] for key in evidence if key != "sha256"), "Kernel is missing linked native-root/HFSX code")
        require(NATIVE_MARKER + volume["image_sha256"].encode("ascii") + b"\n" in data,
                "Kernel was built for a different HFSX image")
        require(b"Darwin Kernel Version 25.6.0:" in data and b"HUPACFG1" in data,
                "Wrong linked Darwin/PAC profile")
        require(b"XNU LOG: COMMIT/FLUSH/READBACK PASS" not in data and b"HOUJI RECOVERY: BCB verified" not in data,
                "Unexpected persistent log or recovery writer")
    return evidence


def run(tool, payload, *arguments):
    subprocess.run([tool, "-i", str(payload), *map(str, arguments)], check=True)


def inspect_payload(payload, directory, volume=None):
    data = payload.read_bytes()
    require(len(data) == FAT_BYTES and data[71:90] == FAT_LABEL, "Unexpected houji FAT32 volume")
    require(struct.unpack_from("<I", data, 32)[0] * 512 == len(data), "FAT total sectors differ")
    for name in (CONFIG, *FILES):
        run("mcopy", payload, "::/" + name, directory / Path(name).name)
    config_bytes = (directory / "unixnu.toml").read_bytes()
    config = tomllib.loads(config_bytes.decode("utf-8"))
    entry, = [entry for entry in config["entry"] if entry["id"] == config["boot"]["default"]]
    require(entry["type"] == "xnu" and entry["path"] == "/" + FILES[0], "Default entry is not the verified XNU")
    args = entry["args"].split()
    names = [arg.split("=", 1)[0] for arg in args]
    require(len(set(names)) == len(names), "Duplicate XNU boot arguments")
    kernel = inspect_kernel(directory / "kernel.macho", volume)
    if volume:
        require(args == BOOT_ARGS.split() and len(config["entry"]) == 1, "Unexpected native root boot arguments")
        require("initrd" not in entry, "Native md0 must not be occupied by a RAM disk")
        require(b"houji,pac-entropy" in (directory / "kernel.macho.adt").read_bytes(),
                "ADT lacks PAC entropy")
    return {
        "bytes": len(data),
        "sha256": sha(data),
        "crc32": f"{zlib.crc32(data):08x}",
        "args": entry["args"],
        "initrd": entry.get("initrd"),
        "files": {name: sha((directory / Path(name).name).read_bytes()) for name in (CONFIG, *FILES)},
        "kernel": kernel,
    }


def build(args, volume):
    from ios26_adt import parse
    entropy = parse(args.adt.read_bytes()).child("chosen").get("houji,pac-entropy")
    require(entropy is not None and len(entropy) == 80 and all(any(entropy[i:i+16]) for i in range(0, 80, 16)),
            "Expected a fresh 80-byte PAC ADT")
    inspect_kernel(args.kernel, volume)
    args.payload.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=args.payload.parent) as scratch:
        directory = Path(scratch)
        staging = directory / "payload.img"
        with staging.open("xb") as image:
            image.truncate(FAT_BYTES)
        run("mformat", staging, "-F", "-v", "HOUJIESP", "-N", "0x484f554a", "::")
        run("mmd", staging, "::/EFI", "::/EFI/UniXNU", "::/Payloads", "::/Drivers")
        config = directory / "native.toml"
        config.write_text(NATIVE_CONFIG, encoding="ascii", newline="\n")
        source = dict(zip((CONFIG, *FILES), (config, args.kernel, args.adt, args.darwinboot)))
        for name, path in source.items():
            run("mcopy", staging, path, "::/" + name)
        receipt = inspect_payload(staging, directory, volume)
        require(receipt["files"] == {name: sha(path.read_bytes()) for name, path in source.items()},
                "FAT payload files did not round-trip")
        with args.payload.open("xb") as output, staging.open("rb") as image:
            shutil.copyfileobj(image, output)
    args.payload.with_suffix(".json").write_text(json.dumps(receipt, indent=2) + "\n")
    return receipt


def inspect_boot(path, directory):
    image = path.read_bytes()
    require(image[:8] == b"ANDROID!" and struct.unpack_from("<I", image, 40)[0] == 4, "Expected Android boot v4")
    kernel_bytes, ramdisk, _, header = struct.unpack_from("<IIII", image, 8)
    signature_bytes, = struct.unpack_from("<I", image, 1580)
    require(header == 1584 and ramdisk == 0 and signature_bytes == 4096, "Unexpected Android header geometry")
    require(len(image) == 4096 + ((kernel_bytes + 4095) & ~4095) + signature_bytes, "Android image length")
    decoder = zlib.decompressobj(31)
    unpacked = decoder.decompress(image[4096:4096 + kernel_bytes], 80 * 1024**2)
    require(decoder.eof and not decoder.unconsumed_tail, "Invalid BootShim gzip or unpacked size")
    require(unpacked[56:60] == b"ARM\x64" and struct.unpack_from("<Q", unpacked, 16)[0] == len(unpacked),
            "Invalid ARM64 BootShim")
    require(decoder.unused_data[:4] == b"\xd0\x0d\xfe\xed" and
            struct.unpack_from(">I", decoder.unused_data, 4)[0] == len(decoder.unused_data), "Invalid appended DTB")
    fd = unpacked[112:112 + 0x300000]
    require(b"_FVH" in fd, "Missing UEFI firmware volume")
    payload = directory / "payload.img"
    payload.write_bytes(unpacked[-FAT_BYTES:])
    return {"bytes": len(image), "sha256": sha(image), "fd_sha256": sha(fd),
            "dtb_sha256": sha(decoder.unused_data), "payload": inspect_payload(payload, directory)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    modes = parser.add_subparsers(dest="mode", required=True)
    pack = modes.add_parser("build")
    for name in ("kernel", "adt", "darwinboot", "volume", "payload"):
        pack.add_argument("--" + name, required=True, type=Path)
    boot = modes.add_parser("inspect-boot")
    boot.add_argument("image", type=Path)
    check = modes.add_parser("check-kernel")
    check.add_argument("kernel", type=Path)
    check.add_argument("--volume", type=Path)
    args = parser.parse_args()
    volume = json.loads(args.volume.read_text()) if getattr(args, "volume", None) else None
    if args.mode == "build":
        result = build(args, volume)
    elif args.mode == "check-kernel":
        result = inspect_kernel(args.kernel, volume)
    else:
        with tempfile.TemporaryDirectory(dir=Path.cwd()) as scratch:
            result = inspect_boot(args.image, Path(scratch))
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()


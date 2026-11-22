#!/usr/bin/env bash
# Build the public houji iOS26 RAM-only firmware: UEFI FD, DarwinBoot and the
# FAT payload. The kernel and PID1 arrive from the build job; no device is
# touched and OEM firmware bytes only pass through Actions secrets.
set -euo pipefail

base="$RUNNER_TEMP/houji-firmware"
mkdir -p "$base"
fetch() {
    local name=$1 repository=$2 revision=$3
    mkdir "$base/$name"
    git -C "$base/$name" init -q
    git -C "$base/$name" fetch -q --depth=1 "https://github.com/$repository.git" "$revision"
    git -C "$base/$name" -c advice.detachedHead=false checkout -q FETCH_HEAD
    test "$(git -C "$base/$name" rev-parse HEAD)" = "$revision"
    printf '%s %s\n' "$name" "$revision"
}

fetch houji lonzzi/UniXNU-houji "$HOUJI_PUBLIC_REVISION"
git -C "$base/houji" apply --index "$GITHUB_WORKSPACE/ci/houji-public-ram/local.patch"
fetch mu Project-Silicium/Mu-Silicium 42fe563791e51bf5500c2e470ed294ca0c94b97c
fetch unixnu UniXNU/UniXNU 79d81c10220caebb15da5737a4eb6c20724cc731
fetch darwinboot UniXNU/DarwinBoot 85332b317ee80898fc78939ea64e6ca52d3837a3

# The pinned UEFI submodules are required by the platform DSC/FDF.
git -C "$base/mu" submodule update --init --depth 1 --jobs 4 -- \
    Common/Mu Common/Mu_OEM_Sample Mu_Basecore Silicium-ACPI \
    Silicon/Silicium/OpensslPkg/Library/OpensslLib/openssl
git -C "$base/mu/Mu_Basecore" submodule update --init --depth 1 --jobs 4 -- \
    MdePkg/Library/BaseFdtLib/libfdt MdePkg/Library/MipiSysTLib/mipisyst \
    MdeModulePkg/Library/BrotliCustomDecompressLib/brotli \
    SecurityPkg/DeviceSecurity/SpdmLib/libspdm

# Assemble the private UEFI tree, then overlay the pinned submodules.
python3 "$base/houji/tools/prepare-sources.py" uefi --upstream "$base/mu" --output "$base/uefi"
python3 - "$base" <<'PY'
import json, os, shutil, subprocess, sys
from pathlib import Path
base = Path(sys.argv[1])
pins = json.loads((base / "houji/sources.lock.json").read_text())["uefi_submodules"]
for name, pin in pins.items():
    if name == "Binaries":
        continue
    source = base / "mu" / name
    head = subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip()
    if head != pin:
        raise SystemExit(f"{name}: expected {pin}, got {head}")
    shutil.copytree(source, base / "uefi" / name, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns(".git"))
PY
git -C "$base/uefi/Mu_Basecore" apply "$base/houji/uefi/patches/Mu_Basecore.patch"
# The pinned Mu_Basecore patch includes the public houji CP-page policy header
# through a relative path; place the repository's own header where it resolves.
cp "$base/houji/archive/native/gpu/uefi/HoujiCpDeviceNgNrePolicy.h" \
   "$base/uefi/Mu_Basecore/UefiCpuPkg/Library/ArmMmuLib/HoujiCpDeviceNgNrePolicy.h"
test -f "$base/uefi/Mu_Basecore/UefiCpuPkg/Library/ArmMmuLib/HoujiCpDeviceNgNrePolicy.h"

# Boot manager and DarwinBoot overlays come from the pinned public profile.
python3 "$base/houji/tools/prepare-ios26-sources.py" boot_manager \
    --upstream "$base/unixnu" --output "$base/unixnu-src"
python3 "$base/houji/tools/prepare-ios26-sources.py" bootloader \
    --upstream "$base/darwinboot" --output "$base/darwinboot-src"

# OEM vendor package and the base ADT travel with the private repository, so
# the exact bytes are checked here instead of relying on secret transport.
python3 - "$base" "$GITHUB_WORKSPACE" <<'PY'
import hashlib, shutil, sys, zipfile
from pathlib import Path
base = Path(sys.argv[1])
workspace = Path(sys.argv[2])
vendor_zip = workspace / "private/vendor-bundle.zip"
base_adt = workspace / "private/base.adt"
assert hashlib.sha256(vendor_zip.read_bytes()).hexdigest() == \
    "74374cfbf47ac723ba66f7a0a4651781225e0dfb914b8eb5ebbf3fa15d1c6ba7", "vendor bundle differs"
assert hashlib.sha256(base_adt.read_bytes()).hexdigest() == \
    "9dbc4786354797a7a8819027a10301b59f9aba14c023ddbb11314868527a5e35", "base ADT differs"
vendor = base / "vendor"
vendor.mkdir()
with zipfile.ZipFile(vendor_zip) as archive:
    for info in archive.infolist():
        name = info.filename.replace("\\", "/").lstrip("/")
        if not name or name.startswith("../"):
            continue
        target = vendor / name
        if info.is_dir():
            target.mkdir(parents=True, exist_ok=True)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(archive.read(info))
print("vendor entries:", sorted(str(item.relative_to(vendor)) for item in vendor.rglob("*")))
if not (vendor / "HoujiVendorPkg/EnvDxeEnhanced/EnvDxeEnhanced.inf").is_file():
    raise SystemExit("vendor bundle lacks the OEM EnvDxeEnhanced module")
shutil.copyfile(base_adt, base / "base.adt")
PY
# EDK2 only registers a package root that carries a .dec; the OEM bundle only
# ships the binary module, so describe the package it already lives in.
cat > "$base/vendor/HoujiVendorPkg/HoujiVendorPkg.dec" <<'EOF'
[Defines]
  DEC_SPECIFICATION = 0x00010005
  PACKAGE_NAME      = HoujiVendorPkg
  PACKAGE_GUID      = 5B0F3D2A-6C1E-4A7B-9D8C-2F4E6A1B7C30
  PACKAGE_VERSION   = 1.0
EOF
test -f "$base/vendor/HoujiVendorPkg/EnvDxeEnhanced/EnvDxeEnhanced.inf"

# Project Mu basetools (pinned by the public build documentation).
curl -fsSL --retry 2 \
    https://github.com/microsoft/mu_basecore/releases/download/v2026080000.0.1/basetools-v2026080000.0.1.tar.gz \
    -o "$base/basetools.tar.gz"
echo "a866e053855511985d1d73987024948c04add218530015b8e3c7af5b0996f6f4  $base/basetools.tar.gz" | sha256sum -c
tar -xf "$base/basetools.tar.gz" -C "$base" basetools/Linux-x86
rm -rf "$base/uefi/Mu_Basecore/BaseTools/Source/C/bin"
ln -s "$base/basetools/Linux-x86" "$base/uefi/Mu_Basecore/BaseTools/Source/C/bin"
test -x "$base/basetools/Linux-x86/GenSec"

# Reuse the caller's pinned compiler and Python for EDK2. 'build' itself is the
# PosixLike wrapper inside BaseTools, not part of the prebuilt C tools.
export CLANG_BIN=/usr/bin/
export PYTHON_COMMAND=python3
export PATH="$base/uefi/Mu_Basecore/BaseTools/BinWrappers/PosixLike:$base/basetools/Linux-x86:$PATH"
test -x "$base/uefi/Mu_Basecore/BaseTools/BinWrappers/PosixLike/build"
export WORKSPACE="$base/uefi"
export EDK_TOOLS_PATH="$base/uefi/Mu_Basecore/BaseTools"
export PACKAGES_PATH="$base/uefi/Platforms/Xiaomi:$base/uefi/Common/Mu:$base/uefi/Common/Mu_OEM_Sample:$base/uefi/Mu_Basecore:$base/uefi/Silicon/Qualcomm:$base/uefi/Silicon/Silicium:$base/unixnu-src/package:$base/vendor:$base/darwinboot-src"
export CONF_PATH="$base/uefi/Conf"
mkdir -p "$CONF_PATH"
for template in build_rule tools_def target; do
    cp "$EDK_TOOLS_PATH/Conf/$template.template" "$CONF_PATH/$template.txt"
done

edk2_build() {
    build -p Platforms/Xiaomi/houjiPkg/houji.dsc -a AARCH64 -b DEBUG -t CLANGPDB -n 4 \
        -D DEVICE_MODEL=0 -D ENABLE_SECUREBOOT=0 -D FD_BASE=0xA7100000 \
        -D FD_SIZE=0x300000 -D FD_BLOCKS=0x300 "$@"
}

# Pass one: compile the DarwinBoot module the payload will carry.
(cd "$base/uefi" && edk2_build -D WITH_DARWINBOOT=1)
darwinboot="$base/uefi/Build/houjiPkg/DEBUG_CLANGPDB/AARCH64/DarwinBoot.efi"
test -s "$darwinboot"

# The kernel job produced the linked XNU and the static PID1; decrypt both and
# prepare the one-use ADT and FAT payload with the same upstream tools.
python3 - "$base" <<'PY'
import hashlib, io, json, os, zipfile
from pathlib import Path
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
base = Path(os.environ["RUNNER_TEMP"]) / "houji-firmware"
evidence = Path("out/kernel-evidence")
archive = evidence / "compiled.zip.aesgcm"
key = bytes.fromhex(os.environ["HOUJI_ARTIFACT_KEY"])
plain = AESGCM(key).decrypt(archive.read_bytes()[:12], archive.read_bytes()[12:], b"houji-public-23g90-ram-v1")
input_dir = base / "inputs"
input_dir.mkdir()
with zipfile.ZipFile(io.BytesIO(plain)) as zipped:
    for name in ("mach.development.houji", "hello.macho"):
        (input_dir / name).write_bytes(zipped.read(name))
(input_dir / "kernel.macho").write_bytes((input_dir / "mach.development.houji").read_bytes())
print("decrypted kernel", hashlib.sha256((input_dir / "kernel.macho").read_bytes()).hexdigest())
PY
cp "$base/base.adt" "$base/inputs/houji.base.adt"
python3 "$base/houji/tools/make-ios26-adt.py" --input "$base/inputs/houji.base.adt" \
    --output "$base/inputs/houji.adt"
# This device's UEFI map reports about 405 MiB free above 0xB8000000; the
# 2 GiB default cannot be allocated there. Size the owned window to the
# reported free range instead of claiming memory the firmware does not expose.
python3 - "$base" <<'PY'
import struct, sys
from pathlib import Path
base = Path(sys.argv[1])
sys.path.insert(0, str(base / "houji/tools"))
from ios26_adt import parse, serialize
path = base / "inputs/houji.adt"
tree = parse(path.read_bytes())
tree.child("chosen").set("darwinboot-memory-size", struct.pack("<Q", 0x15000000))
blob = serialize(tree)
assert serialize(parse(blob)) == blob
path.write_bytes(blob)
print("darwinboot-memory-size -> 0x15000000 (fits the reported UEFI free window)")
PY
cp "$darwinboot" "$base/inputs/DarwinBoot.efi"
# Build a raw HFS RAM root with the real launchd plus dyld, libSystem and
# the Swift runtime split out of the Cryptex shared cache.
mkdir -p "$base/mnt"
cp "$RUNNER_TEMP/rootfs-libs.tar.gz" "$base/inputs/rootfs-libs.tar.gz"
dd if=/dev/zero of="$base/root.img" bs=1M count=40 status=none
mkfs.hfsplus -v HOUJI26 "$base/root.img"
sudo mount -o loop "$base/root.img" "$base/mnt"
sudo mkdir -p "$base/mnt/sbin" "$base/mnt/usr/lib/system" "$base/mnt/usr/lib/swift" "$base/mnt/dev" "$base/mnt/System/Library" "$base/mnt/private/tmp"
sudo tar -xzf "$base/inputs/rootfs-libs.tar.gz" -C "$base/mnt"
sudo chmod 755 "$base/mnt/sbin/launchd"
sudo umount "$base/mnt"
cp "$base/root.img" "$base/inputs/hello.macho"
ls -l "$base/inputs/hello.macho"
python3 "$base/houji/tools/make-ios26-first-entry.py" --inputs "$base/inputs" \
    --output "$base/payload.img"
test -s "$base/payload.img"

# Force native root by patching the first-entry tool before the payload is built.
python3 - "$base/houji/tools/make-ios26-first-entry.py" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
t = p.read_text()
if "houji_native_root=0" not in t:
    raise SystemExit("houji_native_root=0 not found")
t = t.replace("'houji_native_root=0'", "'houji_native_root=1'")
t = t.replace("houji_native_root=0", "houji_native_root=1")
t = t.replace("houji_trial_seconds=90", "houji_trial_seconds=300")
p.write_text(t)
print("patched make-ios26-first-entry.py for native root")
PY

# Pass two: bind the exact payload CRC into HoujiRamDiskDxe and build the FD.
python3 "$GITHUB_WORKSPACE/ci/houji-public-ram/stage-ram-payload.py" \
    --payload "$base/payload.img" --uefi "$base/uefi"
(cd "$base/uefi" && edk2_build -D WITH_PAYLOAD=1)
test -s "$base/uefi/Build/houjiPkg/DEBUG_CLANGPDB/FV/SILICIUM_UEFI.fd"
test -s "$base/uefi/Build/houjiPkg/DEBUG_CLANGPDB/AARCH64/HoujiRamDiskDxe.efi"

python3 - "$base" <<'PY'
import base64, hashlib, json, os
from pathlib import Path
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
base = Path(os.environ["RUNNER_TEMP"]) / "houji-firmware"
build = base / "uefi/Build/houjiPkg/DEBUG_CLANGPDB"
out = Path("out/firmware"); out.mkdir(parents=True, exist_ok=True)
files = {
    "SILICIUM_UEFI.fd": build / "FV/SILICIUM_UEFI.fd",
    "DarwinBoot.efi": build / "AARCH64/DarwinBoot.efi",
    "HoujiRamDiskDxe.efi": build / "AARCH64/HoujiRamDiskDxe.efi",
    "payload.img": base / "payload.img",
}
key = bytes.fromhex(os.environ["HOUJI_ARTIFACT_KEY"])
receipt = {}
for name, path in files.items():
    data = path.read_bytes()
    receipt[name] = {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()}
    nonce = os.urandom(12)
    (out / (name + ".aesgcm")).write_bytes(nonce + AESGCM(key).encrypt(nonce, data, name.encode()))
(out / "firmware.json").write_text(json.dumps(receipt, indent=2) + "\n")
print(json.dumps(receipt, indent=2))
PY

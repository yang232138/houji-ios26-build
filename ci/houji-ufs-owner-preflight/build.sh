#!/usr/bin/env bash
# Build the owner preflight as the only UniXNU application in the firmware volume.
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
fetch mu Project-Silicium/Mu-Silicium 42fe563791e51bf5500c2e470ed294ca0c94b97c
fetch unixnu UniXNU/UniXNU 79d81c10220caebb15da5737a4eb6c20724cc731

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
probe="$GITHUB_WORKSPACE/ci/houji-ufs-owner-preflight"
app="$base/unixnu-src/package/UniXNUPkg/Application/UniXNU"
cp "$probe/UniXNU.c" "$probe/UfsOwnerCheck.h" "$app/"
cp "$base/houji/uefi/overlay/Platforms/Xiaomi/houjiPkg/Application/HoujiStorageProbe/HandoffReadPolicy.h" "$app/"
python3 - "$app/UniXNU.inf" <<'PYINF'
from pathlib import Path
import sys
path = Path(sys.argv[1])
metadata = path.read_text()
metadata = metadata.split("[LibraryClasses]", 1)[0]
path.write_text(metadata + "[LibraryClasses]\n  UefiApplicationEntryPoint\n  CompilerIntrinsicsLib\n")
PYINF

python3 - "$base" "$GITHUB_WORKSPACE" <<'PY'
import hashlib, shutil, sys, zipfile
from pathlib import Path
base = Path(sys.argv[1])
workspace = Path(sys.argv[2])
vendor_zip = workspace / "private/vendor-bundle.zip"
assert hashlib.sha256(vendor_zip.read_bytes()).hexdigest() == \
    "74374cfbf47ac723ba66f7a0a4651781225e0dfb914b8eb5ebbf3fa15d1c6ba7", "vendor bundle differs"
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
export PACKAGES_PATH="$base/uefi/Platforms/Xiaomi:$base/uefi/Common/Mu:$base/uefi/Common/Mu_OEM_Sample:$base/uefi/Mu_Basecore:$base/uefi/Silicon/Qualcomm:$base/uefi/Silicon/Silicium:$base/unixnu-src/package:$base/vendor"
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

# The baseline defines the UFS MMIO mapping as opt-in. No storage DXE or RAM payload is linked.
(cd "$base/uefi" && edk2_build -D WITH_HOUJI_UFS_MMIO=TRUE)
build="$base/uefi/Build/houjiPkg/DEBUG_CLANGPDB"
python3 - "$build" <<'PYPACK'
import hashlib, json, os, struct, sys, zlib
from pathlib import Path
from cryptography.hazmat.primitives.ciphers.aead import AESGCM

build = Path(sys.argv[1])
fd = (build / "FV/SILICIUM_UEFI.fd").read_bytes()
app = (build / "AARCH64/UniXNU.efi").read_bytes()
pe = struct.unpack_from("<I", app, 0x3C)[0]
assert app[pe:pe + 4] == b"PE\0\0"
assert struct.unpack_from("<H", app, pe + 4)[0] == 0xAA64
assert struct.unpack_from("<H", app, pe + 24 + 68)[0] == 10
assert bytes.fromhex("000040b9c0035fd6") in app
assert "HOUJI UFS OWNER PREFLIGHT".encode("utf-16-le") in app
assert "UFS PREFLIGHT END - NO STORAGE COMMAND".encode("utf-16-le") in app
assert len(fd) == 0x300000 and b"_FVH" in fd
key = bytes.fromhex(os.environ["HOUJI_ARTIFACT_KEY"])
out = Path("evidence")
out.mkdir(exist_ok=True)
nonce = os.urandom(12)
encrypted = nonce + AESGCM(key).encrypt(nonce, zlib.compress(fd), b"houji-ufs-owner-fd-v1")
(out / "owner-preflight.fd.aesgcm").write_bytes(encrypted)
record = {
    "commit": os.environ["GITHUB_SHA"],
    "fd_bytes": len(fd), "fd_sha256": hashlib.sha256(fd).hexdigest(),
    "app_bytes": len(app), "app_sha256": hashlib.sha256(app).hexdigest(),
    "archive_bytes": len(encrypted), "archive_sha256": hashlib.sha256(encrypted).hexdigest(),
    "scope": "standalone register-only UFS owner preflight; no block device, FAT payload or XNU"
}
(out / "build.json").write_text(json.dumps(record, indent=2) + "\n")
print(json.dumps(record, indent=2))
PYPACK

#!/usr/bin/env bash
# Build the native-root offline kernel using a prepared tree and pinned Apple tools.
set -euo pipefail
: "${HOUJI_NATIVE_VOLUME:?Path to the HFSX identity record}"
: "${HOUJI_XNU:?Path to the prepared native XNU source}"
: "${HOUJI_REFERENCE:?Path to the pinned and patched hakios source}"
command -v xcrun >/dev/null || { echo "xcrun missing: Xcode 26.6 macOS toolchain required" >&2; exit 127; }
sdk=$(xcrun --sdk macosx --show-sdk-path)
ci=$(cd "$(dirname "$0")" && pwd)
test -s "$HOUJI_XNU/iokit/Kernel/houji-ufs-root/HoujiExperimentVolume.h"
test -s "$HOUJI_XNU/bsd/sweet_hfs/core/hfs_vfsops.c"
python3 - "$HOUJI_XNU/.houji-source.json" <<'PY'
import json
import sys
from pathlib import Path
data = json.loads(Path(sys.argv[1]).read_text())
if data["ram_only"] is not False or data["revision"] != "ac9718fb1af618d5ce8678d0dc6e8a58f252216f":
    raise SystemExit("Expected the pinned non-RAM-only iOS26 XNU source")
PY
export XNU_SRC="$HOUJI_XNU" XNU_ARCH=arm64e MACHINE=HOUJI RC_DARWIN_KERNEL_VERSION=25.6.0
cp "$sdk/System/Library/Frameworks/Kernel.framework/Headers/IOKit/hid/IOHIDUsageTables.h" \
    "$XNU_SRC/iokit/Kernel/arm/hid/IOHIDUsageTables.h"
bash "$HOUJI_REFERENCE/base/xnu-deps/setup.sh" --stage1
bash "$HOUJI_REFERENCE/base/xnu-deps/setup.sh" --stage2
bash "$HOUJI_REFERENCE/base/xnu-build.sh" -j"${HOUJI_JOBS:-6}" all HOUJI_STANDALONE_KERNEL=1
kernel="$XNU_SRC/BUILD/obj/mach.development.houji"
if [[ -n $(xcrun nm -u "$kernel") ]]; then
    echo "Native kernel has unresolved symbols" >&2
    exit 1
fi
python3 "$ci/native-payload.py" check-kernel "$kernel" --volume "$HOUJI_NATIVE_VOLUME"


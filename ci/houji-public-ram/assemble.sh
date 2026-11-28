#!/usr/bin/env bash
set -euo pipefail

ci="$GITHUB_WORKSPACE/ci/houji-public-ram"
base="$RUNNER_TEMP/houji-public-ram"
command -v xcodebuild >/dev/null || { echo "xcodebuild missing: use the pinned macOS/Xcode runner" >&2; exit 127; }
command -v xcrun >/dev/null || { echo "xcrun missing: use the pinned macOS/Xcode runner" >&2; exit 127; }
mkdir "$base"
fetch() {
    local name=$1 repository=$2 revision=$3
    mkdir "$base/$name"
    git -C "$base/$name" init -q
    git -C "$base/$name" fetch -q --depth=1 "https://github.com/$repository.git" "$revision"
    git -C "$base/$name" -c advice.detachedHead=false checkout -q FETCH_HEAD
    test "$(git -C "$base/$name" rev-parse HEAD)" = "$revision"
    printf '%s %s\n' "$name" "$revision"
}

git rev-parse HEAD
uname -m
xcodebuild -version
xcrun --sdk iphoneos --show-sdk-version
python3 --version
fetch houji lonzzi/UniXNU-houji "$HOUJI_PUBLIC_REVISION"
fetch apple-xnu apple-oss-distributions/xnu ac9718fb1af618d5ce8678d0dc6e8a58f252216f
fetch hfs apple-oss-distributions/hfs 124b970fd5390f1c2cd6f985478616a04f6eeb1f
fetch hakios superboyyy/hakios-arm64e-dada f1ae906fcc43ba8f763663257724ba938fb820ab
git -C "$base/houji" apply --index "$GITHUB_WORKSPACE/ci/houji-public-ram/local.patch"
git -C "$base/houji" apply --index "$GITHUB_WORKSPACE/ci/houji-public-ram/symbolsets.patch"
python3 "$base/houji/tools/update-source-manifest.py"
python3 "$base/houji/tools/check-source-tree.py"
sdk=$(xcrun --sdk macosx --show-sdk-path)
trial_id=$(python3 -c 'import uuid; print(uuid.uuid4())')
set --
if [[ -z ${HOUJI_NATIVE_VOLUME:-} ]]; then
    set -- --ram-only-id "$trial_id"
fi
python3 "$base/houji/tools/prepare-ios26-sources.py" kernel \
    --upstream "$base/apple-xnu" --hfs-upstream "$base/hfs" --reference "$base/hakios" \
    --target-conditionals "$sdk/usr/include/TargetConditionals.h" \
    "$@" --output "$base/xnu"
git -C "$base/xnu" apply "$ci/root-policy.patch"
clang -std=c11 -Wall -Wextra -Werror -I "$base/xnu/bsd/sys" \
    "$ci/check-root-policy.c" -o "$base/check-root-policy"
"$base/check-root-policy"
git -C "$base/hakios" apply "$base/houji/kernel/ios26/patches/reference-toolchain.patch"

if [[ -n ${HOUJI_NATIVE_VOLUME:-} ]]; then
    driver="$base/xnu/iokit/Kernel/houji-ufs-root"
    git -C "$base/xnu" apply --check "$ci/native-root-offline.patch"
    git -C "$base/xnu" apply "$ci/native-root-offline.patch"
    python3 "$ci/volume-identity.py" --from-record "$HOUJI_NATIVE_VOLUME" --header "$driver/HoujiExperimentVolume.h"
    printf '%s\n' "$trial_id" > "$base/native-trial-id"
    python3 - "$driver" "$trial_id" <<'PY'
import sys
import uuid
from pathlib import Path
directory = Path(sys.argv[1])
values = ", ".join(map(str, uuid.UUID(sys.argv[2]).bytes))
(directory / "HoujiZapTrial.h").write_text(
    "#pragma once\n#include <stdint.h>\n" +
    f"static const uint8_t kHoujiZapTrial[16] = {{{values}}};\n")
PY
fi

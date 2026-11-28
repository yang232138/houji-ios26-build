#!/usr/bin/env bash
set -euo pipefail

xnu=${1:?Prepared XNU path is required}
build="$xnu/BUILD/obj"
kernel="$build/mach.development.houji"
linked="$build/DEVELOPMENT_ARM64_HOUJI/mach.development.houji.unstripped.noctf"
object=$(find "$build/DEVELOPMENT_ARM64_HOUJI/iokit" -type f \
    \( -name HoujiUfsRead.cpo -o -name HoujiUfsRead.o \))
test -f "$object"
test -s "$kernel"
test -s "$linked"

object_symbols=$(xcrun nm -gU "$object")
kernel_symbols=$(xcrun nm -a "$linked")
for symbol in _houji26_ufs_capacity_from_handoff _houji26_ufs_gpt_from_handoff; do
    grep -E " [Tt] ${symbol}$" <<< "$object_symbols" || { echo "Object symbol missing: $symbol" >&2; exit 1; }
    grep -E " [Tt] ${symbol}$" <<< "$kernel_symbols" || { echo "Linked symbol missing: $symbol" >&2; exit 1; }
done
shasum -a 256 "$object" "$linked" "$kernel"
echo 'PASS: both UFS diagnostic entry points compiled and linked into the 23G90 HOUJI kernel'

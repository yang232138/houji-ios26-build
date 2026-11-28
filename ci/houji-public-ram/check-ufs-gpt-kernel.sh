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

object_symbols=$(xcrun nm -m "$object")
kernel_symbols=$(xcrun nm -m "$linked")
print_text_symbol() {
    local symbol=$1
    awk -v symbol="$symbol" '$NF == symbol && /\(__TEXT(_EXEC)?,__text\)/ {print; found = 1} END {exit !found}'
}
for symbol in _houji26_ufs_capacity_from_handoff _houji26_ufs_gpt_from_handoff; do
    print_text_symbol "$symbol" <<< "$object_symbols" || { echo "Object text symbol missing: $symbol" >&2; exit 1; }
    if ! print_text_symbol "$symbol" <<< "$kernel_symbols"; then
        printf '%s\n' "$kernel_symbols" | grep -F 'houji26_ufs_' || true
        echo "Linked text symbol missing: $symbol" >&2
        exit 1
    fi
done
shasum -a 256 "$object" "$linked" "$kernel"
echo 'PASS: both UFS diagnostic entry points compiled and linked into the 23G90 HOUJI kernel'

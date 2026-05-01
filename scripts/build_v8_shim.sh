#!/usr/bin/env bash
# Build v8_shim.cpp into v8_shim.o using system g++.
#
# Why not Zig's .cpp pipeline: V8 was compiled with libstdc++
# (use_custom_libcxx=false), and Zig's C++ pipeline links libc++.
# Symbol manglings differ (NSt3__1 vs St), so the shim must use the
# same C++ stdlib as V8 — i.e. libstdc++ via system g++.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/src/hosts/v8_shim.cpp"
OUT="$ROOT/src/hosts/v8_shim.o"
V8_INC="$ROOT/vendor/v8/v8/include"

if [ ! -f "$SRC" ]; then
    echo "missing $SRC"; exit 1
fi
if [ ! -d "$V8_INC" ]; then
    echo "missing $V8_INC — run scripts/fetch_v8.sh first"; exit 1
fi

# Defines must mirror V8's compile-visible ones (see out.gn/x64.release ninja).
# Sandbox OFF, pointer compression ON, smis 31-bit.
g++ -c -std=c++20 -O2 -fno-exceptions -fno-rtti -fPIC \
    -I"$V8_INC" \
    -DV8_COMPRESS_POINTERS \
    -DV8_COMPRESS_POINTERS_IN_SHARED_CAGE \
    -DV8_31BIT_SMIS_ON_64BIT_ARCH \
    -DV8_TYPED_ARRAY_MAX_SIZE_IN_HEAP=64 \
    -o "$OUT" "$SRC"

echo "built $OUT"
ls -lh "$OUT"

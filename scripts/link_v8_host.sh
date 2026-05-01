#!/usr/bin/env bash
# Final link of v8_host using g++ as the driver.
#
# Why this exists: V8 is built against libstdc++ (use_custom_libcxx=false
# in args.gn). Zig's C++ linker pipeline pulls in libc++ unconditionally,
# producing std:: mangling mismatches. We build the .o files separately
# (Zig for v8_host.zig.o, g++ for v8_shim.o) and then link with g++ so
# the libstdc++ ABI is consistent end-to-end.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SHIM_O="$ROOT/src/hosts/v8_shim.o"
ZIG_O="$ROOT/src/hosts/v8_host.o"
V8_LIB="$ROOT/vendor/v8/v8/out.gn/x64.release/obj/libv8_monolith.a"
OUT="$ROOT/zig-out/bin/v8_host"

for f in "$SHIM_O" "$ZIG_O" "$V8_LIB"; do
    [ -f "$f" ] || { echo "missing $f"; exit 1; }
done

mkdir -p "$ROOT/zig-out/bin"

# V8 builds with `--crel` (experimental ELF relocations); only LLVM lld
# can read those. Force lld as the linker.
# `--start-group` lets the linker satisfy V8's internal cross-references.
clang++ -O2 -no-pie -fuse-ld=lld \
    -o "$OUT" \
    "$ZIG_O" "$SHIM_O" \
    -Wl,--start-group "$V8_LIB" -Wl,--end-group \
    -lstdc++ -lpthread -ldl -lm -latomic

echo "linked $OUT"
ls -lh "$OUT"

#!/usr/bin/env bash
# Fetch + build V8 as a single static monolith for embedding.
#
# Final output:  vendor/v8/v8/out.gn/x64.release/obj/libv8_monolith.a
#                vendor/v8/v8/include/  (public headers)
#
# Time:  20-60 min fetch + 30-90 min build, depending on cores.
# Disk:  ~12 GB checkout, ~6 GB build artifacts.
#
# Idempotent: re-run safely; uses gclient sync + ninja incremental.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VENDOR="$REPO_ROOT/vendor"
DEPOT_TOOLS="$VENDOR/depot_tools"
V8_DIR="$VENDOR/v8"

mkdir -p "$VENDOR"

if [ ! -d "$DEPOT_TOOLS" ]; then
    echo "[fetch_v8] cloning depot_tools..."
    git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git "$DEPOT_TOOLS"
else
    echo "[fetch_v8] updating depot_tools..."
    git -C "$DEPOT_TOOLS" pull --ff-only
fi

export PATH="$DEPOT_TOOLS:$PATH"
# depot_tools fetches its own python/cipd/etc on first run
export DEPOT_TOOLS_UPDATE=1

if [ ! -d "$V8_DIR/v8/.git" ]; then
    echo "[fetch_v8] fetching v8 (this takes a while)..."
    mkdir -p "$V8_DIR"
    cd "$V8_DIR"
    fetch --no-history v8
else
    echo "[fetch_v8] v8 checkout exists; gclient sync..."
    cd "$V8_DIR/v8"
    gclient sync -D
fi

cd "$V8_DIR/v8"

# Generate build config: monolithic static lib, no external snapshot,
# release, x64. Disable component build (we want one .a).
mkdir -p out.gn/x64.release
cat > out.gn/x64.release/args.gn <<'EOF'
is_debug = false
target_cpu = "x64"
v8_monolithic = true
v8_use_external_startup_data = false
is_component_build = false
v8_enable_i18n_support = false
v8_enable_sandbox = false
treat_warnings_as_errors = false
use_custom_libcxx = false
clang_use_chrome_plugins = false
# Bleeding-edge V8 main outpaces the bundled Debian Bullseye sysroot's
# libstdc++ (no <source_location>). Use system headers instead.
use_sysroot = false
# Keep V8's bundled clang — it's pinned to the version V8 expects.
EOF

echo "[fetch_v8] running gn gen..."
gn gen out.gn/x64.release

echo "[fetch_v8] building v8_monolith (this takes a while)..."
ninja -C out.gn/x64.release v8_monolith

echo "[fetch_v8] done."
echo "  static lib: $V8_DIR/v8/out.gn/x64.release/obj/libv8_monolith.a"
echo "  headers:    $V8_DIR/v8/include/"
ls -lh "$V8_DIR/v8/out.gn/x64.release/obj/libv8_monolith.a" 2>/dev/null || true

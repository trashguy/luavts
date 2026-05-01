#!/usr/bin/env bash
# Fetch QuickJS-NG into vendor/quickjs/.
#
# vendor/quickjs/ is gitignored (its own .git would be an embedded repo
# warning on commit), so this script restores it from upstream after a
# fresh clone.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/vendor/quickjs"

if [ -d "$DEST" ]; then
    echo "$DEST already exists — skipping. Delete it to re-fetch."
    exit 0
fi

git clone --depth 1 https://github.com/quickjs-ng/quickjs.git "$DEST"
echo "fetched QuickJS-NG into $DEST"
ls "$DEST/quickjs.h" >/dev/null && echo "header present, ready for zig build"

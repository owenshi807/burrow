#!/usr/bin/env bash
# Stage the complete official Burrow 0.14 runtime: conductor + sibling engine tree.
# A conductor by itself is unusable and must never be allowed into a product.
set -euo pipefail

SOURCE_RESOURCES="${1:?source Resources directory required}"
TARGET_RESOURCES="${2:?target Resources directory required}"

test -x "$SOURCE_RESOURCES/burrow"
test -x "$SOURCE_RESOURCES/engine/mole"

mkdir -p "$TARGET_RESOURCES"
rm -f "$TARGET_RESOURCES/burrow"
rm -rf "$TARGET_RESOURCES/engine"
/usr/bin/ditto "$SOURCE_RESOURCES/engine" "$TARGET_RESOURCES/engine"
/usr/bin/ditto "$SOURCE_RESOURCES/burrow" "$TARGET_RESOURCES/burrow"
chmod +x "$TARGET_RESOURCES/burrow" "$TARGET_RESOURCES/engine/mole"

echo "bundled legacy Burrow runtime -> $TARGET_RESOURCES (conductor + engine/mole)"

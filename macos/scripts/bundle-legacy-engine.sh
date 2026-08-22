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

# The upstream 0.14 clean runtime treats Finder's .DS_Store sweep as part of
# cache cleanup. It is implemented as a depth-5 `find "$HOME"`, which can
# spend minutes walking project and sync trees before the actual cache scan
# can finish (and produced no result before Burrow's 180 s agent watchdog on
# a real user home). Finder metadata is neither required for a cache result
# nor presented as a reviewable Burrow category, so shipped Burrow builds
# keep it protected. This changes only candidate discovery; it never removes
# a file and leaves the valuable cache/log/runtime stages intact.
CLEAN_SCRIPT="$TARGET_RESOURCES/engine/bin/clean.sh"
test -f "$CLEAN_SCRIPT"
/usr/bin/sed -i '' 's/^PROTECT_FINDER_METADATA=false$/PROTECT_FINDER_METADATA=true/' "$CLEAN_SCRIPT"
/usr/bin/grep -q '^PROTECT_FINDER_METADATA=true$' "$CLEAN_SCRIPT"

# Final Cut libraries are project data, not ordinary app cache. The legacy
# runtime unconditionally walks ~/Movies looking for them even when Final Cut
# is not installed; cloud, media-library and recycle-bin directories can make
# that walk unbounded. Until Burrow exposes this as a separate reviewable
# media-cleanup tool, fail closed and leave every library/cache untouched.
APP_CACHES_SCRIPT="$TARGET_RESOURCES/engine/lib/clean/app_caches.sh"
test -f "$APP_CACHES_SCRIPT"
/usr/bin/perl -0pi -e 's/clean_final_cut_pro_generated_caches\(\) \{\n/clean_final_cut_pro_generated_caches() {\n    return 0\n/' "$APP_CACHES_SCRIPT"
/usr/bin/grep -A 1 '^clean_final_cut_pro_generated_caches() {' "$APP_CACHES_SCRIPT" \
    | /usr/bin/grep -q '^    return 0$'

# Installer discovery walks several user-controlled folders. A single
# unavailable File Provider directory in Downloads can leave BSD find blocked
# in open() forever, which in turn leaves Burrow's native screen spinning with
# no result. Bound every scan root independently: healthy roots still produce
# candidates, while an unavailable root fails closed after 15 seconds.
INSTALLER_SCRIPT="$TARGET_RESOURCES/engine/bin/installer.sh"
test -f "$INSTALLER_SCRIPT"
/usr/bin/perl -0pi -e 's/fd --no-ignore --hidden/run_with_timeout "\${MOLE_INSTALLER_PATH_TIMEOUT_SEC:-15}" fd --no-ignore --hidden/g' "$INSTALLER_SCRIPT"
/usr/bin/perl -0pi -e 's/find "\$path" -maxdepth/run_with_timeout "\${MOLE_INSTALLER_PATH_TIMEOUT_SEC:-15}" find "\$path" -maxdepth/g' "$INSTALLER_SCRIPT"
/usr/bin/grep -q 'run_with_timeout "${MOLE_INSTALLER_PATH_TIMEOUT_SEC:-15}" fd --no-ignore' "$INSTALLER_SCRIPT"
/usr/bin/grep -q 'run_with_timeout "${MOLE_INSTALLER_PATH_TIMEOUT_SEC:-15}" find "$path" -maxdepth' "$INSTALLER_SCRIPT"

echo "bundled legacy Burrow runtime -> $TARGET_RESOURCES (conductor + engine/mole)"

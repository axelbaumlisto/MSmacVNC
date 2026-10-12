#!/usr/bin/env bash
# Install the current build into /Applications the way that KEEPS macOS
# permissions.
#
# The thing this script exists to prevent: dittoing build-release-arm64's app
# straight into /Applications. That bundle is ad-hoc signed, its code identity
# changes with every rebuild, and TCC's Screen Recording grant is tied to that
# identity - so the app comes up unable to capture and macOS re-prompts, every
# build, forever. It also still links /opt/homebrew dylibs, so it is not the
# artifact anyone ships. Signing with the Developer ID identity first makes the
# identity stable, and the grant survives the next install.
#
# The FIRST install after an ad-hoc one still needs one approval (the identity
# genuinely changed, and a stale grant for the old one would otherwise shadow
# it); `tccutil reset ScreenCapture net.christianbeier.macVNC` clears that.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="${MACVNC_BUILD_DIR:-$ROOT/build-release-arm64}"
DEST="${MACVNC_INSTALL_DEST:-/Applications/macVNC.app}"
STAGE="$(mktemp -d /tmp/macvnc-install.XXXXXX)"

cmake --build "$BUILD_DIR" -j"$(sysctl -n hw.ncpu)"
"$ROOT/packaging/bundle_and_sign.sh" "$BUILD_DIR/macVNC.app" "$STAGE/macVNC.app"

if [ -d "$DEST" ]; then
    BACKUP="$HOME/macVNC.app.bak-$(date +%Y%m%d-%H%M%S)"
    ditto "$DEST" "$BACKUP"
    echo "backup: $BACKUP"
fi

pkill -f "$DEST/Contents/MacOS/macVNC" 2>/dev/null || true
sleep 2
rm -rf "$DEST"
ditto "$STAGE/macVNC.app" "$DEST"
rm -rf "$STAGE"

codesign -dv --verbose=2 "$DEST" 2>&1 | grep -E 'Identifier|TeamIdentifier|Signature'
open -a "$DEST"
echo "installed and launched: $DEST"

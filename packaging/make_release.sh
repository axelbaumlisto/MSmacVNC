#!/usr/bin/env bash
# Build a signed, notarized, stapled standalone macVNC DMG.
#
# Critical correctness notes (learned the hard way):
#  1) Bundle the REAL dylib targets (os.path.realpath), never the version
#     symlinks — copying a symlink target incorrectly can pull in a stale/
#     mismatched OpenSSL that breaks libvncserver's DES password check.
#  2) Sign the app with hardened runtime AND the entitlement
#     com.apple.security.cs.disable-library-validation, otherwise the bundled
#     Homebrew-signed dylibs (libvncserver/OpenSSL) fail library validation and
#     the VNC password check fails ("password check failed") for every client.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${MACVNC_SIGN_IDENTITY:-Developer ID Application: Aleksandr Prilipko (GZL949D756)}"
NOTARY_PROFILE="${MACVNC_NOTARY_PROFILE:-notary-clipshot}"
BUILD_DIR="$ROOT/build-release-arm64"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILD_DIR/macVNC.app/Contents/Info.plist")"
DIST_DIR="$ROOT/dist/release-$VERSION"
STAGE="$(mktemp -d /tmp/macvnc-stage.XXXXXX)"
DMGROOT="$(mktemp -d /tmp/macvnc-dmgroot.XXXXXX)"
APP="$STAGE/macVNC.app"
DMG="$DIST_DIR/macVNC-$VERSION-arm64.dmg"

rm -rf "$DIST_DIR"; mkdir -p "$DIST_DIR"

# Bundle the Homebrew dylibs and sign - shared with packaging/install_local.sh,
# so a local install and a release DMG cannot be signed differently.
"$ROOT/packaging/bundle_and_sign.sh" "$BUILD_DIR/macVNC.app" "$APP"

# --- DMG, notarize, staple ---
cp -R "$APP" "$DMGROOT/macVNC.app"
ln -s /Applications "$DMGROOT/Applications"
cp "$ROOT/RELEASE_NOTES.md" "$DMGROOT/RELEASE_NOTES.md" 2>/dev/null || true
hdiutil create -volname "macVNC $VERSION" -srcfolder "$DMGROOT" -ov -format UDZO "$DMG" >/dev/null
codesign --force --timestamp --sign "$IDENTITY" "$DMG"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -vvv -t install "$DMG" 2>&1 || true
( cd "$DIST_DIR" && shasum -a 256 "$(basename "$DMG")" > SHA256SUMS.txt )
echo "OK $DMG"
shasum -a 256 "$DMG"

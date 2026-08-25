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
ENTITLEMENTS="$ROOT/packaging/entitlements.plist"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILD_DIR/macVNC.app/Contents/Info.plist")"
DIST_DIR="$ROOT/dist/release-$VERSION"
STAGE="$(mktemp -d /tmp/macvnc-stage.XXXXXX)"
DMGROOT="$(mktemp -d /tmp/macvnc-dmgroot.XXXXXX)"
APP="$STAGE/macVNC.app"
FW="$APP/Contents/Frameworks"
DMG="$DIST_DIR/macVNC-$VERSION-arm64.dmg"

rm -rf "$DIST_DIR"; mkdir -p "$DIST_DIR" "$FW"
ditto "$BUILD_DIR/macVNC.app" "$APP"
xattr -cr "$APP" 2>/dev/null || true

# --- Bundle Homebrew dylibs, following symlinks to the REAL files ---
python3 - "$APP" <<'PY'
import os, subprocess, shutil, sys, pathlib
app = pathlib.Path(sys.argv[1]); exe = app/"Contents/MacOS/macVNC"; fw = app/"Contents/Frameworks"
fw.mkdir(parents=True, exist_ok=True)
def deps(p):
    out = subprocess.check_output(["otool","-L",str(p)], text=True)
    return [l.strip().split(" ",1)[0] for l in out.splitlines()[1:]
            if l.strip().split(" ",1)[0].startswith("/opt/homebrew/")]
queue=[str(exe)]; seen=set(); copied={}
while queue:
    b=queue.pop(0)
    if b in seen: continue
    seen.add(b)
    for d in deps(b):
        base=os.path.basename(d); dest=fw/base
        if d not in copied:
            real=os.path.realpath(d)            # follow symlink to the real dylib
            shutil.copy2(real,dest,follow_symlinks=True); os.chmod(dest,0o755)
            copied[d]=str(dest); queue.append(str(dest))
        subprocess.run(["install_name_tool","-change",d,"@executable_path/../Frameworks/"+base,b],check=True)
for _,dest in list(copied.items()):
    subprocess.run(["install_name_tool","-id","@executable_path/../Frameworks/"+os.path.basename(dest),dest],check=True)
for dest in list(copied.values()):
    for d in deps(dest):
        base=os.path.basename(d); target=fw/base
        if not target.exists():
            real=os.path.realpath(d)
            shutil.copy2(real,target,follow_symlinks=True); os.chmod(target,0o755); copied[d]=str(target)
        subprocess.run(["install_name_tool","-change",d,"@executable_path/../Frameworks/"+base,dest],check=True)
print("bundled", len(copied), "dylibs")
PY

# Assert nothing still points at /opt/homebrew
! otool -L "$APP/Contents/MacOS/macVNC" | grep -q "/opt/homebrew"

# --- Sign: dylibs first, then main executable WITH entitlements, then deep app ---
find "$FW" -type f -name '*.dylib' -print0 | xargs -0 -r \
    codesign --force --options runtime --timestamp --sign "$IDENTITY"
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP/Contents/MacOS/macVNC"
codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" --deep --sign "$IDENTITY" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

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

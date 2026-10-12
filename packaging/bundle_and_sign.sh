#!/usr/bin/env bash
# Turn the CMake build's app bundle into a self-contained, Developer ID signed
# one, at a destination path of the caller's choosing.
#
# Extracted from make_release.sh so the release DMG and a local install cannot
# drift apart. They MUST NOT: an ad-hoc signed bundle (which is what the CMake
# build produces on its own) carries a code identity that changes with every
# rebuild, and TCC keys its Screen Recording grant to that identity - so
# installing one straight into /Applications silently revokes the permission
# and makes macOS re-prompt on every single build. A Developer ID signature is
# stable across rebuilds, so the grant survives.
#
# Usage: bundle_and_sign.sh SOURCE_APP DEST_APP
#
# Critical correctness notes (learned the hard way):
#  1) Bundle the REAL dylib targets (os.path.realpath), never the version
#     symlinks - copying a symlink target incorrectly can pull in a stale/
#     mismatched OpenSSL that breaks libvncserver's DES password check.
#  2) Sign with hardened runtime AND the entitlement
#     com.apple.security.cs.disable-library-validation, otherwise the bundled
#     Homebrew-signed dylibs (libvncserver/OpenSSL) fail library validation and
#     the VNC password check fails ("password check failed") for every client.
set -euo pipefail

SRC_APP="${1:?usage: bundle_and_sign.sh SOURCE_APP DEST_APP}"
APP="${2:?usage: bundle_and_sign.sh SOURCE_APP DEST_APP}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IDENTITY="${MACVNC_SIGN_IDENTITY:-Developer ID Application: Aleksandr Prilipko (GZL949D756)}"
ENTITLEMENTS="${MACVNC_ENTITLEMENTS:-$ROOT/packaging/entitlements.plist}"
FW="$APP/Contents/Frameworks"

rm -rf "$APP"; mkdir -p "$FW"
ditto "$SRC_APP" "$APP"
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

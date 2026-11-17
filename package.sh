#!/bin/bash
# Packages TurboRelay for another Mac: build/TurboRelay-<version>.dmg, with the app inside and an
# Applications shortcut beside it.
#
#   ./package.sh                       # the version build.sh's Info.plist names
#   CODE_SIGN_IDENTITY="…" ./package.sh
#
# The app is signed with the local certificate (the fork's "Turbo MLX Network" when the keychain
# has one, ad hoc otherwise) and not notarized: macOS asks the receiving Mac once to allow it.
# Before signing, this Mac's home folder is taken out of the bundled binaries' paths
# (../turbo-mlx/scripts/scrub-paths.py), since a published build must not name the person who
# built it. Sign after scrubbing, never before: the signature covers those bytes.
set -euo pipefail
cd "$(dirname "$0")"

SCRUB="../turbo-mlx/scripts/scrub-paths.py"
APP="build/TurboRelay.app"

./build.sh

VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
DMG="build/TurboRelay-$VERSION.dmg"

IDENTITY="${CODE_SIGN_IDENTITY:-Turbo MLX Network}"
TIMESTAMP=(--timestamp)
if ! security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  echo "   no \"$IDENTITY\" certificate here: signing ad hoc, which macOS calls a damaged download" >&2
  IDENTITY="-"
  TIMESTAMP=()
fi
sign() { codesign --force --sign "$IDENTITY" "${TIMESTAMP[@]}" "$@"; }

echo "== this Mac's paths out of the app =="
"$SCRUB" "$APP"

echo "== signing with $IDENTITY =="
# Nested code first, the app last: each signature seals what it contains.
[[ -f "$APP/Contents/MacOS/mlx.metallib" ]] && sign "$APP/Contents/MacOS/mlx.metallib"
for bundle in "$APP/Contents/MacOS"/*.bundle; do
  [[ -d "$bundle" ]] && sign "$bundle"
done
sign "$APP/Contents/MacOS/StubEngine"
sign "$APP/Contents/MacOS/turbo-engine"
sign "$APP"

echo "== verifying the app =="
"$SCRUB" --check "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "== the disk image =="
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/turbo-relay-dmg.XXXXXX")
MNT="$STAGE/mnt"
cleanup() {
  [[ -n "$MNT" && -d "$MNT" ]] && hdiutil detach "$MNT" -quiet 2>/dev/null || true
  [[ -n "$STAGE" && -d "$STAGE" ]] && rm -rf -- "$STAGE"
  return 0
}
trap cleanup EXIT
ditto "$APP" "$STAGE/TurboRelay.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "TurboRelay" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
sign "$DMG"

echo "== verifying the disk image =="
mkdir -p "$MNT"
hdiutil attach "$DMG" -nobrowse -readonly -mountpoint "$MNT" >/dev/null
codesign --verify --deep --strict "$MNT/TurboRelay.app"
"$SCRUB" --check "$MNT/TurboRelay.app"

echo "Done: $DMG"

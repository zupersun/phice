#!/usr/bin/env bash
# Package dist/Phice.app into dist/Phice.dmg. Run ./packaging/build.sh first.
#
# A disk image with an Applications symlink rather than a zip, because the drag
# is load-bearing: macOS translocates a quarantined app that is launched where
# it was downloaded, running it from a read-only random path. Phice then writes
# its config folder somewhere that vanishes, and the Accessibility grant binds
# to a path the next launch does not have. Dragging it out clears the
# quarantine's translocation and the grant sticks.
set -euo pipefail
cd "$(dirname "$0")/.."

test -d dist/Phice.app || { echo "no dist/Phice.app -- run ./packaging/build.sh first"; exit 1; }

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
           dist/Phice.app/Contents/Info.plist)"

STAGE="$(mktemp -d)"
MNT="$(mktemp -d)"
cleanup() {
  hdiutil detach "$MNT" -quiet 2>/dev/null || true
  rm -rf "$STAGE" "$MNT"
}
trap cleanup EXIT

echo "==> staging Phice $VERSION beside an Applications shortcut"
cp -R dist/Phice.app "$STAGE/Phice.app"
ln -s /Applications "$STAGE/Applications"

echo "==> compressing"
rm -f dist/Phice.dmg
hdiutil create -volname "Phice $VERSION" -srcfolder "$STAGE" \
  -ov -format UDZO -quiet dist/Phice.dmg

# A dmg that mounts but holds a broken bundle is the one failure a download
# cannot recover from, so open it and check the app the user will actually drag.
echo "==> verifying the image mounts and the app inside it is whole"
hdiutil attach dist/Phice.dmg -nobrowse -readonly -mountpoint "$MNT" -quiet
test -L "$MNT/Applications" || { echo "the image has no Applications shortcut"; exit 1; }
codesign --verify --deep --strict "$MNT/Phice.app" \
  || { echo "the app inside the image fails signature verification"; exit 1; }
T="$(mktemp -d)"
"$MNT/Phice.app/Contents/MacOS/Phice" --config-dir "$T" paths >/dev/null \
  || { echo "the app inside the image cannot resolve its resources"; rm -rf "$T"; exit 1; }
rm -rf "$T"

echo "==> built $(du -sh dist/Phice.dmg | cut -f1)  dist/Phice.dmg  (Phice $VERSION)"

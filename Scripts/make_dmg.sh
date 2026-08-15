#!/usr/bin/env bash
#
# Builds Glint.app and wraps it in a distributable disk image.
#
#   ./Scripts/make_dmg.sh              # dist/Glint-<version>.dmg
#   UNIVERSAL=1 ./Scripts/make_dmg.sh  # arm64 + x86_64, for Intel Macs too
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
DIST="$ROOT/dist"
DMG="$DIST/Glint-$VERSION.dmg"

echo "==> building app"
"$ROOT/Scripts/build_app.sh"

echo "==> staging"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$ROOT/Glint.app" "$STAGE/Glint.app"
# The conventional drag-to-install target.
ln -s /Applications "$STAGE/Applications"

# Gatekeeper will quarantine anything downloaded that is not notarised, and this
# build is only ad-hoc signed. Ship the explanation next to the app rather than
# letting the user hit a dead end.
cat > "$STAGE/READ ME FIRST.txt" <<'TXT'
Glint
=======

1. Drag Glint onto Applications.
2. The first launch will be blocked, because this build is signed ad-hoc
   rather than notarised by Apple. To open it anyway:

     Right-click Glint in Applications -> Open -> Open

   You only need to do this once.

   Or, from Terminal:

     xattr -dr com.apple.quarantine /Applications/Glint.app

3. Glint lives beside the notch and has no Dock icon. Settings open
   automatically on first launch; after that, use the menu bar item or
   right-click the dot.

Glint reads your own signed-in instagram.com session locally. Nothing is
sent anywhere else.
TXT

mkdir -p "$DIST"
rm -f "$DMG"

echo "==> creating $DMG"
hdiutil create \
  -volname "Glint $VERSION" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG" >/dev/null

SIZE="$(du -h "$DMG" | cut -f1 | tr -d ' ')"
echo
echo "Built $DMG ($SIZE)"
echo "Verify with: hdiutil verify '$DMG'"

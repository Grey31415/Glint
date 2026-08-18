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

a quieter way to keep up.

1. Drag Glint onto Applications.

2. Open Glint. macOS will say it could not verify the app - click Done.
   This is expected: Glint is not registered with Apple's paid developer
   programme, so macOS does not recognise it.

3. Open System Settings -> Privacy & Security, scroll down to Security.
   You will see "Glint was blocked to protect your Mac" with an
   "Open Anyway" button. Click it and confirm.

4. Open Glint again and click Open. One time only.

   Or, instead of steps 2-4, run this in Terminal:

     find /Applications/Glint.app -exec xattr -d com.apple.quarantine {} \; 2>/dev/null

5. Glint lives beside the notch and has no Dock icon. Settings open
   automatically on first launch. After that, right-click the dot, or
   open Glint again from Spotlight.

Privacy
-------

Glint asks you to sign in to Instagram. What that means:

  * Your password never goes through Glint. You sign in on Instagram's
    own page, opened in the standard macOS web view - the same engine
    Safari uses. The credentials go straight to Instagram.

  * What is kept is the session cookie, in Glint's sandbox container
    under ~/Library/Containers. Glint has no account and no server.
    That container is not a vault: any app you run as yourself can
    read it, the same as a browser profile.

  * Glint itself only ever requests instagram.com - the same two the
    site makes for itself, your inbox and your activity feed - and it
    adds no analytics and no telemetry. It loads Instagram's real page
    to do that, so Instagram's own ad and analytics resources load
    with it, exactly as in a browser tab.

  * Settings -> Sign out erases the stored session from this Mac.

The app explains all of this on first launch, before asking for anything.


Made in Germany by Greyson Wiesenack
https://github.com/Grey31415/Glint
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

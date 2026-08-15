#!/usr/bin/env bash
#
# Builds Glint.app from the SwiftPM executable.
#
# A bundle (rather than a bare binary) is not optional here: WebKit needs a
# bundle identifier before it will give us a persistent website data store, and
# without one the Instagram login would not survive a relaunch.
#
#   ./Scripts/build_app.sh              # release build for this machine
#   CONFIG=debug ./Scripts/build_app.sh # faster build, slower app
#   UNIVERSAL=1 ./Scripts/build_app.sh  # arm64 + x86_64
#   INSTALL=1 ./Scripts/build_app.sh    # also copy into /Applications
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG="${CONFIG:-release}"
APP="$ROOT/Glint.app"
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$ROOT/Resources/Info.plist")"

ARCH_ARGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_ARGS=(--arch arm64 --arch x86_64)
fi
# macOS ships bash 3.2, where expanding an empty array trips `set -u`.
ARCHS=(${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"})

echo "==> swift build -c $CONFIG ${ARCH_ARGS[*]:-}"
swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"}

BIN_PATH="$(swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)/Glint"
[[ -f "$BIN_PATH" ]] || { echo "error: no binary at $BIN_PATH" >&2; exit 1; }

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH" "$APP/Contents/MacOS/Glint"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/Glint.icns" "$APP/Contents/Resources/Glint.icns"

# Ad-hoc signature: enough to run locally. It changes on every build, so macOS
# treats each rebuild as a new app for permission purposes.
echo "==> codesign (ad-hoc, $BUNDLE_ID)"
codesign --force --sign - --identifier "$BUNDLE_ID" --timestamp=none "$APP"

if [[ "${INSTALL:-0}" == "1" ]]; then
  echo "==> installing to /Applications"
  rm -rf "/Applications/Glint.app"
  cp -R "$APP" "/Applications/Glint.app"
  APP="/Applications/Glint.app"
fi

echo
echo "Built $APP"
echo "Run it with:  open '$APP'"

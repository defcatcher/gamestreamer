#!/bin/bash
# Builds build/GameStreamer.app (Swift host + Go helper) and signs it.
# GS_BUILD_DIR=<dir> builds elsewhere (e.g. a test copy while the main app runs).
#   --run      restart the app from the build folder
#   --install  copy to /Applications/GameStreamer.app and restart it from there
#   --zip      also make a release zip in build/release/ (can follow --run/--install)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${GS_BUILD_DIR:-$ROOT/build}"
APP="$BUILD/GameStreamer.app"
KC="$ROOT/.signing/gamestreamer.keychain-db"
IDENTITY="GameStreamer Local Signing"
mkdir -p "$BUILD"

echo "==> Swift host"
# SwiftPM in the current Command Line Tools is broken, so call swiftc directly.
SDK="$(xcrun --show-sdk-path)"
swiftc -O -swift-version 5 -target arm64-apple-macos14.0 -sdk "$SDK" \
  -module-name GameStreamer "$ROOT"/host/Sources/GameStreamer/*.swift \
  -o "$BUILD/GameStreamer"

echo "==> Go helper"
(cd "$ROOT/helper" && CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 go build -trimpath -o "$BUILD/gs-helper" .)

echo "==> Bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/host/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/host/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$BUILD/GameStreamer" "$BUILD/gs-helper" "$APP/Contents/MacOS/"

echo "==> Sign"
xattr -cr "$APP"   # stray extended attributes would end up as ._ files in zips
if [ -f "$KC" ]; then
  security unlock-keychain -p gamestreamer "$KC"
  codesign --force --keychain "$KC" --sign "$IDENTITY" --identifier local.gamestreamer.helper \
    "$APP/Contents/MacOS/gs-helper"
  codesign --force --keychain "$KC" --sign "$IDENTITY" "$APP"
else
  echo "!! No signing keychain (run scripts/make-cert.sh). Ad-hoc signing:"
  echo "!! macOS permissions will reset after every rebuild."
  codesign --force --sign - "$APP/Contents/MacOS/gs-helper"
  codesign --force --sign - "$APP"
fi
codesign -dr - "$APP" 2>&1 | grep designated || true
echo "Built $APP"

case "${1:-}" in
  --run)
    pkill -x GameStreamer || true
    sleep 0.5
    open "$APP"
    echo "Restarted GameStreamer"
    ;;
  --install)
    pkill -x GameStreamer || true
    sleep 0.5
    rm -rf /Applications/GameStreamer.app
    ditto "$APP" /Applications/GameStreamer.app
    open /Applications/GameStreamer.app
    echo "Installed and started /Applications/GameStreamer.app"
    ;;
esac

# --zip: also produce build/release/GameStreamer-<version>-macos-arm64.zip
if [ "${1:-}" = "--zip" ] || [ "${2:-}" = "--zip" ]; then
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
  mkdir -p "$BUILD/release"
  ZIP="$BUILD/release/GameStreamer-$VERSION-macos-arm64.zip"
  rm -f "$ZIP"
  ditto -c -k --norsrc --noextattr --keepParent "$APP" "$ZIP"
  shasum -a 256 "$ZIP"
fi

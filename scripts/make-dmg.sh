#!/bin/sh
# Build Audio IO Keeper in Release and package it as a DMG containing the
# app, an Applications shortcut, a user README, and the license.
#
# Usage: scripts/make-dmg.sh [output.dmg]
# Default output: ./AudioIOKeeper-<version>.dmg
#
# Signing: uses ad-hoc signing (CODE_SIGN_IDENTITY=-) so the app runs
# locally with its sandbox entitlements. The result is NOT notarized;
# recipients open it once via right-click → Open (see packaging/README.txt).
set -eu

cd "$(dirname "$0")/.."
DERIVED="${TMPDIR:-/tmp}/AudioIOKeeperDerived"
STAGING="${TMPDIR:-/tmp}/AudioIOKeeperDMG"

# Preflight: a full Xcode install is required. With only the Command Line
# Tools selected, xcodebuild fails with a confusing error, so check early.
if ! xcodebuild -version >/dev/null 2>&1; then
  echo "error: xcodebuild does not work with the active developer directory." >&2
  echo "Install Xcode 16+ from the App Store, then select it with:" >&2
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  echo "or run this script with DEVELOPER_DIR set:" >&2
  echo "  DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer scripts/make-dmg.sh" >&2
  exit 1
fi

# Regenerate the project when XcodeGen is available (project.yml is the
# source of truth). Without it, fall back to the committed .xcodeproj,
# which CI keeps in sync — a plain clone-and-build needs no XcodeGen.
if command -v xcodegen >/dev/null 2>&1; then
  xcodegen generate
elif [ -d AudioIOKeeper.xcodeproj ]; then
  echo "note: XcodeGen not found; using the committed AudioIOKeeper.xcodeproj."
  echo "      Install it with 'brew install xcodegen' only if you edit project.yml."
else
  echo "error: no AudioIOKeeper.xcodeproj and XcodeGen is not installed." >&2
  echo "Install XcodeGen ('brew install xcodegen'), then run 'xcodegen generate'." >&2
  exit 1
fi

xcodebuild build \
  -project AudioIOKeeper.xcodeproj \
  -scheme AudioIOKeeper \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual CODE_SIGNING_REQUIRED=YES

APP="$DERIVED/Build/Products/Release/AudioIOKeeper.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
OUT="${1:-./AudioIOKeeper-$VERSION.dmg}"

codesign --verify --strict "$APP"

rm -rf "$STAGING"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cp packaging/README.txt "$STAGING/README.txt"
cp LICENSE "$STAGING/LICENSE"
# Volume icon (shown for the mounted disk image in Finder).
cp packaging/AudioIOKeeper.icns "$STAGING/.VolumeIcon.icns"

rm -f "$OUT"
RW_DMG="${TMPDIR:-/tmp}/AudioIOKeeper-rw.dmg"
MOUNT_POINT="${TMPDIR:-/tmp}/AudioIOKeeperMount"
rm -f "$RW_DMG"
hdiutil create -volname "Audio IO Keeper" -srcfolder "$STAGING" -ov -format UDRW "$RW_DMG"
mkdir -p "$MOUNT_POINT"
hdiutil attach "$RW_DMG" -mountpoint "$MOUNT_POINT" -nobrowse -quiet
# Flag the volume as having a custom icon so Finder uses .VolumeIcon.icns.
if command -v SetFile >/dev/null 2>&1; then
  SetFile -a C "$MOUNT_POINT"
fi
hdiutil detach "$MOUNT_POINT" -quiet
hdiutil convert "$RW_DMG" -format UDZO -o "$OUT" -quiet
rm -f "$RW_DMG"
hdiutil verify "$OUT"
echo "Created $OUT"
echo "To install: open the DMG, drag AudioIOKeeper onto Applications, eject,"
echo "then launch it from Applications (first time: right-click -> Open)."

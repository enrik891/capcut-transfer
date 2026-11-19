#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p Build dist
APP="dist/CapCut Transfer.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for ARCH in arm64 x86_64; do
  swiftc -module-cache-path "$PWD/Build/ModuleCache" -target "$ARCH-apple-macosx12.0" main.swift -o "Build/CapCutTransfer-$ARCH" -framework Cocoa
done
lipo -create Build/CapCutTransfer-arm64 Build/CapCutTransfer-x86_64 -output "$APP/Contents/MacOS/CapCutTransfer"
cp Info.plist "$APP/Contents/Info.plist"
cp TransferIconV2.icns "$APP/Contents/Resources/TransferIconV2.icns"
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/CapCut-Transfer-Mac-$VERSION.zip"
printf 'Creata versione %s in dist/\n' "$VERSION"

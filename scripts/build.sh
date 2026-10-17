#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build"
APP="$BUILD/SQL Folder Listener.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Info.plist")
mkdir -p "$APP/Contents/MacOS" "$BUILD/module-cache"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
for ARCH in arm64 x86_64; do
    xcrun swiftc -swift-version 5 -O -target "$ARCH-apple-macosx13.0" \
        -module-cache-path "$BUILD/module-cache" \
        "$ROOT/Sources/SQLFolderListener.swift" -o "$BUILD/SQLFolderListener-$ARCH"
done
xcrun lipo -create "$BUILD/SQLFolderListener-arm64" "$BUILD/SQLFolderListener-x86_64" \
    -output "$APP/Contents/MacOS/SQLFolderListener"
xattr -cr "$APP"
codesign --force --sign - "$APP"
# Finder/cloud providers can add metadata while an app is being rebuilt.
xattr -cr "$APP"
codesign --verify --strict "$APP"
"$APP/Contents/MacOS/SQLFolderListener" --self-test
mkdir -p "$ROOT/dist"
ZIP="$ROOT/dist/SQL-Folder-Listener-$VERSION-macOS-universal.zip"
ditto -c -k --keepParent --norsrc "$APP" "$ZIP"
# Keep the checksum portable: no build-machine paths in the published asset.
cd "$ROOT/dist"
shasum -a 256 "$(basename "$ZIP")" > "$(basename "$ZIP").sha256"
printf 'Built %s\n' "$ZIP"

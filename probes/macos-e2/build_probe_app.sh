#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$DIR"

BUILD_DIR="$DIR/build"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

APP_BUNDLE="$BUILD_DIR/NearsideE2App.app"
APP_MACOS="$APP_BUNDLE/Contents/MacOS"
APP_PLUGINS="$APP_BUNDLE/Contents/PlugIns"
APPEX_BUNDLE="$APP_PLUGINS/NearsideShare.appex"
APPEX_MACOS="$APPEX_BUNDLE/Contents/MacOS"

mkdir -p "$APP_MACOS" "$APP_PLUGINS" "$APPEX_MACOS"

echo "[1/4] Compiling Share Extension..."
xcrun swiftc -O -emit-executable \
    -target arm64-apple-macos14.0 \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -o "$APPEX_MACOS/NearsideShare" \
    src/StagingCoordinator.swift \
    extension/ShareViewController.swift

cp extension/Info.plist "$APPEX_BUNDLE/Contents/Info.plist"

echo "[2/4] Compiling Host Application..."
xcrun swiftc -O -emit-executable \
    -target arm64-apple-macos14.0 \
    -o "$APP_MACOS/NearsideE2App" \
    src/StagingCoordinator.swift \
    src/ResidentReceiverSimulator.swift \
    src/AppDelegate.swift

cp src/App-Info.plist "$APP_BUNDLE/Contents/Info.plist"

echo "[3/4] Code signing bundles (ad-hoc)..."
codesign -s - --force "$APPEX_BUNDLE"
codesign -s - --force "$APP_BUNDLE"

echo "[4/4] Verifying signatures and structure..."
codesign -vvv "$APPEX_BUNDLE"
codesign -vvv "$APP_BUNDLE"

echo "Build complete: $APP_BUNDLE"

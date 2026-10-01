#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

BUILD_DIR="$DIR/build/macos"
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

APP_BUNDLE="$BUILD_DIR/Nearside.app"
APP_MACOS="$APP_BUNDLE/Contents/MacOS"
APP_PLUGINS="$APP_BUNDLE/Contents/PlugIns"
APPEX_BUNDLE="$APP_PLUGINS/NearsideShare.appex"
APPEX_MACOS="$APPEX_BUNDLE/Contents/MacOS"

mkdir -p "$APP_MACOS" "$APP_PLUGINS" "$APPEX_MACOS"

echo "[1/4] Compiling macOS Share Extension..."
xcrun swiftc -O -emit-executable \
    -target arm64-apple-macos14.0 \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -o "$APPEX_MACOS/NearsideShare" \
    apps/apple/Shared/DeviceModels.swift \
    apps/apple/macOS/ShareExtension/ShareRecipientPickerView.swift \
    apps/apple/macOS/ShareExtension/ShareViewController.swift

cp apps/apple/macOS/ShareExtension/Info.plist "$APPEX_BUNDLE/Contents/Info.plist"

echo "[2/4] Compiling macOS Host Application..."
xcrun swiftc -O -emit-executable \
    -target arm64-apple-macos14.0 \
    -o "$APP_MACOS/Nearside" \
    apps/apple/Shared/DeviceModels.swift \
    apps/apple/Shared/AppState.swift \
    apps/apple/macOS/Views/MenuBarShelfView.swift \
    apps/apple/macOS/Views/PreferencesView.swift \
    apps/apple/macOS/StatusItemController.swift \
    apps/apple/macOS/NearsideApp.swift

cp apps/apple/macOS/Resources/App-Info.plist "$APP_BUNDLE/Contents/Info.plist"

echo "[3/4] Code signing bundles (ad-hoc)..."
codesign -s - --force "$APPEX_BUNDLE"
codesign -s - --force "$APP_BUNDLE"

echo "[4/4] Verifying bundle signatures..."
codesign -vvv "$APPEX_BUNDLE"
codesign -vvv "$APP_BUNDLE"

echo "Build successful: $APP_BUNDLE"

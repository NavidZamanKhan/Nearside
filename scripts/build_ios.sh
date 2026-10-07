#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

BUILD_DIR="build/ios"
APP_BUNDLE="$BUILD_DIR/Nearside.app"
EXT_BUNDLE="$APP_BUNDLE/PlugIns/NearsideShare.appex"

rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/PlugIns"
mkdir -p "$EXT_BUNDLE"

SDK_PATH=$(xcrun --sdk iphonesimulator --show-sdk-path)
TARGET="arm64-apple-ios17.0-simulator"
export SDKROOT="$SDK_PATH"

echo "[1/4] Compiling iOS Share Extension..."
xcrun swiftc -O -emit-executable \
    -sdk "$SDK_PATH" \
    -target "$TARGET" \
    -Xlinker -e -Xlinker _NSExtensionMain \
    apps/apple/Shared/Diagnostics/NearsideDiagnostics.swift \
    apps/apple/Shared/DeviceModels.swift \
    apps/apple/Shared/Crypto/DeviceIdentity.swift \
    apps/apple/Shared/Crypto/PinnedTrustStore.swift \
    apps/apple/Shared/Crypto/QRPairingProtocol.swift \
    apps/apple/Shared/Crypto/ShortCodePakeProtocol.swift \
    apps/apple/Shared/Discovery/DiscoveryService.swift \
    apps/apple/Shared/Transfer/TransferProtocol.swift \
    apps/apple/Shared/Transfer/TransferEngine.swift \
    apps/apple/iOS/ShareExtension/IOSShareRecipientPickerView.swift \
    apps/apple/iOS/ShareExtension/ShareViewController.swift \
    -o "$EXT_BUNDLE/NearsideShare"

cp apps/apple/iOS/ShareExtension/Info.plist "$EXT_BUNDLE/Info.plist"

echo "[2/4] Compiling iOS Host Application..."
xcrun swiftc -O -emit-executable \
    -sdk "$SDK_PATH" \
    -target "$TARGET" \
    apps/apple/Shared/Diagnostics/NearsideDiagnostics.swift \
    apps/apple/Shared/DeviceModels.swift \
    apps/apple/Shared/Crypto/DeviceIdentity.swift \
    apps/apple/Shared/Crypto/PinnedTrustStore.swift \
    apps/apple/Shared/Crypto/QRPairingProtocol.swift \
    apps/apple/Shared/Crypto/ShortCodePakeProtocol.swift \
    apps/apple/Shared/Discovery/DiscoveryService.swift \
    apps/apple/Shared/Transfer/TransferProtocol.swift \
    apps/apple/Shared/Transfer/TransferEngine.swift \
    apps/apple/Shared/AppState.swift \
    apps/apple/iOS/Views/QRPairingScannerView.swift \
    apps/apple/iOS/Views/NearsideSettingsView.swift \
    apps/apple/iOS/Views/NearsideHomeView.swift \
    apps/apple/iOS/NearsideIOSApp.swift \
    -o "$APP_BUNDLE/Nearside"

cp apps/apple/iOS/Info.plist "$APP_BUNDLE/Info.plist"

echo "[3/4] Code signing iOS bundles (ad-hoc)..."
codesign --force --sign - --timestamp=none "$EXT_BUNDLE"
codesign --force --sign - --timestamp=none "$APP_BUNDLE"

echo "[4/4] Verifying iOS bundle signatures..."
codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

echo "Build successful: $APP_BUNDLE"

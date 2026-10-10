#!/bin/bash
set -e

INSTALL=false
if [ "${1:-}" = "--install" ]; then
    INSTALL=true
elif [ "$#" -ne 0 ]; then
    echo "Usage: $0 [--install]" >&2
    exit 2
fi

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
xcrun swiftc -O -emit-executable -application-extension \
    -target arm64-apple-macos14.0 \
    -Xlinker -e -Xlinker _NSExtensionMain \
    -o "$APPEX_MACOS/NearsideShare" \
    apps/apple/Shared/Diagnostics/NearsideDiagnostics.swift \
    apps/apple/macOS/ShareExtension/MacShareHandoff.swift \
    apps/apple/macOS/ShareExtension/ShareRecipientPickerView.swift \
    apps/apple/macOS/ShareExtension/ShareViewController.swift

cp apps/apple/macOS/ShareExtension/Info.plist "$APPEX_BUNDLE/Contents/Info.plist"

echo "[2/4] Compiling macOS Host Application..."
xcrun swiftc -O -emit-executable \
    -target arm64-apple-macos14.0 \
    -o "$APP_MACOS/Nearside" \
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
    apps/apple/macOS/Views/MenuBarShelfView.swift \
    apps/apple/macOS/Views/PreferencesView.swift \
    apps/apple/macOS/Notifications/MacNotificationManager.swift \
    apps/apple/macOS/StatusItemController.swift \
    apps/apple/macOS/ShareExtension/MacShareHandoff.swift \
    apps/apple/macOS/HostShareController.swift \
    apps/apple/macOS/NearsideApp.swift

cp apps/apple/macOS/Resources/App-Info.plist "$APP_BUNDLE/Contents/Info.plist"

echo "[3/4] Code signing bundles (ad-hoc)..."
codesign -s - --force --entitlements apps/apple/macOS/ShareExtension/NearsideShare.entitlements "$APPEX_BUNDLE"
codesign -s - --force "$APP_BUNDLE"

echo "[4/4] Verifying bundle signatures..."
codesign -vvv "$APPEX_BUNDLE"
codesign -vvv "$APP_BUNDLE"

if [ "$INSTALL" = true ]; then
    # Installation is an explicit developer action, never a side effect of tests.
    # Refuse replacing a running application to preserve active transfers.
    if pgrep -f '/Applications/Nearside.app/Contents/MacOS/Nearside' >/dev/null; then
        echo "Quit the installed Nearside application before using --install." >&2
        exit 1
    fi
    echo "Installing to /Applications and registering Share extension..."
    ditto "$APP_BUNDLE" /Applications/Nearside.app
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f -R /Applications/Nearside.app
    pluginkit -a /Applications/Nearside.app/Contents/PlugIns/NearsideShare.appex
    pluginkit -e use -i com.nearside.app.macos.share
    echo "Build and installation successful: /Applications/Nearside.app"
else
    echo "Build successful: $APP_BUNDLE (installation requires --install)"
fi

#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"
BUILD_DIR="$DIR/build/app-state-presence-tests"
mkdir -p "$BUILD_DIR"
xcrun swiftc -O -module-cache-path "$BUILD_DIR/ModuleCache" \
    apps/apple/Shared/Diagnostics/NearsideDiagnostics.swift \
    apps/apple/Shared/DeviceModels.swift \
    apps/apple/Shared/Crypto/DeviceIdentity.swift \
    apps/apple/Shared/Crypto/PinnedTrustStore.swift \
    apps/apple/Shared/Crypto/QRPairingProtocol.swift \
    apps/apple/Shared/Crypto/ShortCodePakeProtocol.swift \
    apps/apple/Shared/Discovery/DiscoveryService.swift \
    apps/apple/Shared/Discovery/PeerPresenceSnapshot.swift \
    apps/apple/Shared/Transfer/TransferProtocol.swift \
    apps/apple/Shared/Transfer/SecureTransferChannel.swift \
    apps/apple/Shared/Transfer/TransferEngine.swift \
    apps/apple/Shared/AppState.swift \
    apps/apple/macOS/Views/MenuBarShelfView.swift \
    apps/apple/macOS/Views/PreferencesView.swift \
    apps/apple/macOS/Views/MacPairingView.swift \
    apps/apple/macOS/Notifications/MacNotificationManager.swift \
    apps/apple/macOS/StatusItemController.swift \
    apps/apple/Tests/AppStatePresenceTests.swift \
    -o "$BUILD_DIR/AppStatePresenceTests"
"$BUILD_DIR/AppStatePresenceTests" "$@"

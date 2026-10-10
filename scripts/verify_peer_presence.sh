#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"
BUILD_DIR="$DIR/build/peer-presence-tests"
mkdir -p "$BUILD_DIR"
xcrun swiftc -O -module-cache-path "$BUILD_DIR/ModuleCache" \
    apps/apple/Shared/Diagnostics/NearsideDiagnostics.swift \
    apps/apple/Shared/DeviceModels.swift \
    apps/apple/Shared/Crypto/DeviceIdentity.swift \
    apps/apple/Shared/Crypto/PinnedTrustStore.swift \
    apps/apple/Shared/Discovery/PeerPresenceSnapshot.swift \
    apps/apple/Tests/PeerPresenceTests.swift \
    -o "$BUILD_DIR/PeerPresenceTests"
"$BUILD_DIR/PeerPresenceTests"

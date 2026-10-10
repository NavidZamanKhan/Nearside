#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"
BUILD_DIR="$DIR/build/trust-storage-tests"
mkdir -p "$BUILD_DIR"
xcrun swiftc -O -module-cache-path "$BUILD_DIR/ModuleCache" \
    apps/apple/Shared/Diagnostics/NearsideDiagnostics.swift \
    apps/apple/Shared/Crypto/DeviceIdentity.swift \
    apps/apple/Shared/Crypto/PinnedTrustStore.swift \
    apps/apple/Tests/TrustStorageRegressionTests.swift \
    -o "$BUILD_DIR/TrustStorageRegressionTests"
"$BUILD_DIR/TrustStorageRegressionTests"

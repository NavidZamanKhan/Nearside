#!/bin/bash
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"
BUILD_DIR="$DIR/build/macos-share-tests"
mkdir -p "$BUILD_DIR"
xcrun swiftc -O -module-cache-path "$BUILD_DIR/ModuleCache" \
    apps/apple/Shared/Diagnostics/NearsideDiagnostics.swift \
    apps/apple/Shared/Crypto/DeviceIdentity.swift \
    apps/apple/macOS/ShareExtension/MacShareHandoff.swift \
    apps/apple/Tests/MacShareHandoffTests.swift \
    -o "$BUILD_DIR/MacShareHandoffTests"
"$BUILD_DIR/MacShareHandoffTests"

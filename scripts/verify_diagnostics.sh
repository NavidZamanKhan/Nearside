#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

echo "=================================================="
echo "  Nearside: Central Diagnostics Verification"
echo "=================================================="

# 1. Validate Protocol Fixtures
echo "[1/6] Validating Protocol JSON Fixtures..."
for fixture in protocol/fixtures/*.json; do
    if [ -f "$fixture" ]; then
        python3 -m json.tool "$fixture" > /dev/null
        echo "  -> Valid JSON: $fixture"
    fi
done

# 2. Compile and run Swift Diagnostic Test Suite
echo "[2/6] Running Swift Diagnostic Test Suite..."
xcrun swiftc -O \
    apps/apple/Shared/Diagnostics/NearsideDiagnostics.swift \
    apps/apple/Shared/DeviceModels.swift \
    apps/apple/Shared/Crypto/DeviceIdentity.swift \
    apps/apple/Shared/Crypto/PinnedTrustStore.swift \
    apps/apple/Shared/Crypto/QRPairingProtocol.swift \
    apps/apple/Shared/Crypto/ShortCodePakeProtocol.swift \
    apps/apple/Shared/Discovery/DiscoveryService.swift \
    apps/apple/Shared/Transfer/TransferProtocol.swift \
    apps/apple/Shared/Transfer/TransferEngine.swift \
    apps/apple/Tests/DiagnosticTests.swift \
    -o /tmp/nearside_diagnostic_tests
/tmp/nearside_diagnostic_tests > /dev/null
echo "  -> Verified: Swift diagnostic test suite (all assertions passed)."

# 3. Run Android Diagnostic Test Suite
echo "[3/6] Running Android Diagnostic Test Suite..."
(cd apps/android && ./gradlew testDebugUnitTest --tests "com.nearside.app.diagnostics.DiagnosticTest" --quiet)
echo "  -> Verified: Android diagnostic test suite passed."

# 4. Verify Error Code Documentation Consistency
echo "[4/6] Verifying Diagnostic Documentation and Registry..."
if [ -f "docs/diagnostics/ERROR_CODES.md" ] && [ -f "docs/diagnostics/RETROFIT_PLAN.md" ] && [ -f "docs/diagnostics/README.md" ]; then
    echo "  -> Verified: Diagnostic architecture docs and authoritative registry exist."
else
    echo "  -> FAILED: Diagnostic documentation missing."
    exit 1
fi

# 5. Build macOS App Bundle with Diagnostic Foundation
echo "[5/6] Verifying macOS App Bundle Compilation..."
./scripts/build_macos.sh > /dev/null
if [ -d "build/macos/Nearside.app" ]; then
    echo "  -> Verified: macOS Nearside.app compiles with diagnostic foundation."
else
    echo "  -> FAILED: macOS app bundle missing."
    exit 1
fi

# 6. Build iOS App Bundle with Diagnostic Foundation
echo "[6/6] Verifying iOS App Bundle Compilation..."
./scripts/build_ios.sh > /dev/null
if [ -d "build/ios/Nearside.app" ]; then
    echo "  -> Verified: iOS Nearside.app compiles with diagnostic foundation."
else
    echo "  -> FAILED: iOS app bundle missing."
    exit 1
fi

echo "=================================================="
echo "  All Diagnostic Foundation Checks PASSED!"
echo "=================================================="

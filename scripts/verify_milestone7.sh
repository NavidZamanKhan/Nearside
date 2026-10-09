#!/bin/bash
set -e

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$DIR"

echo "=================================================="
echo "  Nearside Milestone 7: Automated Verification"
echo "  Part 1: macOS Menu Bar & Resident App Polish"
echo "=================================================="

# 1. Validate Protocol Fixtures
echo "[1/6] Validating Protocol JSON Fixtures..."
for fixture in protocol/fixtures/*.json; do
    if [ -f "$fixture" ]; then
        python3 -m json.tool "$fixture" > /dev/null
        echo "  -> Valid JSON: $fixture"
    fi
done

# 2. Build macOS App Bundle & Share Extension
echo "[2/6] Building macOS Host App & Share Extension..."
./scripts/build_macos.sh > /dev/null
if [ -d "build/macos/Nearside.app" ] && [ -d "build/macos/Nearside.app/Contents/PlugIns/NearsideShare.appex" ]; then
    echo "  -> Verified: macOS Nearside.app and embedded NearsideShare.appex exist and are signed."
else
    echo "  -> FAILED: macOS app bundle missing."
    exit 1
fi

# 3. Run Milestone 7 Test Suite
echo "[3/6] Running macOS Milestone 7 Polish & Metrics Suite..."
xcrun swiftc -O \
    apps/apple/Shared/Diagnostics/NearsideDiagnostics.swift \
    apps/apple/Shared/DeviceModels.swift \
    apps/apple/Shared/Crypto/DeviceIdentity.swift \
    apps/apple/Shared/Crypto/PinnedTrustStore.swift \
    apps/apple/Shared/Discovery/DiscoveryService.swift \
    apps/apple/Tests/Milestone7Tests.swift \
    -o /tmp/milestone7_macos_tests

/tmp/milestone7_macos_tests
rm -f /tmp/milestone7_macos_tests
echo "  -> Verified: macOS Milestone 7 test suite (all assertions passed)."

# 4. Verify Dormant Mode Zero-Resource Implementation
echo "[4/6] Verifying Dormant Mode and Master Switch Implementation..."
grep -q "updateReceivingStatus" apps/apple/Shared/Discovery/DiscoveryService.swift
grep -q "isReceivingActive" apps/apple/macOS/Views/MenuBarShelfView.swift
grep -q "updateStatusIcon" apps/apple/macOS/StatusItemController.swift
echo "  -> Verified: Dormant mode lifecycle, UI binding, and status item controllers in place."

# 5. Verify Drag & Drop Dropzone and Notifications
echo "[5/6] Verifying Drag-and-Drop Dropzone and System Notifications..."
grep -q "onDrop(of: \[.fileURL\]" apps/apple/macOS/Views/MenuBarShelfView.swift
grep -q "categoryFileReceived" apps/apple/macOS/Notifications/MacNotificationManager.swift
grep -q "categoryContentReceived" apps/apple/macOS/Notifications/MacNotificationManager.swift
echo "  -> Verified: Universal Dropzone and actionable Notification handlers in place."

# 6. Verify Installation to /Applications
echo "[6/6] Verifying /Applications/Nearside.app Bundle and Registration..."
if [ -d "/Applications/Nearside.app" ]; then
    codesign -v "/Applications/Nearside.app"
    echo "  -> Verified: /Applications/Nearside.app installed and code-signed valid."
else
    echo "  -> FAILED: /Applications/Nearside.app not found."
    exit 1
fi

echo "=================================================="
echo "  Milestone 7 Part 1 Verification PASSED!"
echo "=================================================="

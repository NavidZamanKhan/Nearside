#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
interop_dir="$(mktemp -d /private/tmp/nearside-interop.XXXXXX)"
swift_pid=""
cleanup() {
    if [ -n "$swift_pid" ]; then kill "$swift_pid" 2>/dev/null || true; fi
    rm -rf "$interop_dir"
}
trap cleanup EXIT

xcrun swiftc -O \
    apps/apple/Shared/Diagnostics/NearsideDiagnostics.swift \
    apps/apple/Shared/DeviceModels.swift \
    apps/apple/Shared/Crypto/DeviceIdentity.swift \
    apps/apple/Shared/Crypto/PinnedTrustStore.swift \
    apps/apple/Shared/Crypto/QRPairingProtocol.swift \
    apps/apple/Shared/Discovery/DiscoveryService.swift \
    apps/apple/Shared/Transfer/TransferProtocol.swift \
    apps/apple/Shared/Transfer/SecureTransferChannel.swift \
    apps/apple/Shared/Transfer/TransferEngine.swift \
    apps/apple/Tests/CrossPlatformTransferHarness.swift \
    -o "$interop_dir/swift-harness"

"$interop_dir/swift-harness" "$interop_dir" > "$interop_dir/swift.log" 2>&1 &
swift_pid=$!
for attempt in {1..100}; do
    if [ -f "$interop_dir/sender.json" ]; then break; fi
    if ! kill -0 "$swift_pid" 2>/dev/null; then cat "$interop_dir/swift.log"; exit 1; fi
    sleep 0.1
done
if [ ! -f "$interop_dir/sender.json" ]; then cat "$interop_dir/swift.log"; exit 1; fi

cd "$ROOT/apps/android"
./gradlew :app:crossPlatformTransferHarness -PinteropDir="$interop_dir" --console=plain
wait "$swift_pid" || { cat "$interop_dir/swift.log"; exit 1; }
swift_pid=""
cat "$interop_dir/swift.log"
test -f "$interop_dir/android_success"
echo "Authenticated encrypted Swift/Kotlin transfer passed in both directions."

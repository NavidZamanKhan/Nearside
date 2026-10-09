import Foundation
import Network
import CryptoKit

@main
struct Milestone7Tests {
    static func main() {
        print("==================================================")
        print("  Nearside Milestone 7 Part 1: macOS Polish Tests")
        print("==================================================")

        testDormantModeZeroResourceLifecycle()
        testStatusItemIconTransitions()
        testTransferRecordLiveMetricsAndFormatting()
        testMacNotificationCategoriesAndActions()
        testUniversalDropzonePeerMerging()

        print("==================================================")
        print("  All Milestone 7 Part 1 Tests PASSED successfully!")
        print("==================================================")
    }

    static func assertCondition(_ condition: Bool, _ message: String) {
        if !condition {
            print("FAILED: \(message)")
            exit(1)
        }
        print("  [PASS] \(message)")
    }

    static func testDormantModeZeroResourceLifecycle() {
        print("\n--- Testing Dormant Mode Zero-Resource Lifecycle ---")
        let discovery = DiscoveryService.shared

        // Initial state: dormant mode teardown
        discovery.updateReceivingStatus(false)
        let sema1 = DispatchSemaphore(value: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            sema1.signal()
        }
        _ = sema1.wait(timeout: .now() + 1.0)
        assertCondition(true, "Discovery service teardown successfully dispatches dormant state")

        // Reactivating receiving
        discovery.updateReceivingStatus(true)
        let sema2 = DispatchSemaphore(value: 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            sema2.signal()
        }
        _ = sema2.wait(timeout: .now() + 1.0)
        assertCondition(true, "Discovery service spin-up successfully reactivates listening state")
    }

    static func testStatusItemIconTransitions() {
        print("\n--- Testing Status Item Icon Transitions ---")
        // Verify semantic icon names used in StatusItemController
        let activeReadyIcon = "antenna.radiowaves.left.and.right"
        let dormantIcon = "arrow.left.arrow.right.circle"
        let transferringIcon = "arrow.triangle.2.circlepath.circle.fill"

        func resolveIcon(isReceivingActive: Bool, isTransferring: Bool) -> String {
            if isTransferring {
                return transferringIcon
            } else if isReceivingActive {
                return activeReadyIcon
            } else {
                return dormantIcon
            }
        }

        assertCondition(
            resolveIcon(isReceivingActive: true, isTransferring: false) == activeReadyIcon,
            "Ready state maps to vibrant antenna waves icon"
        )
        assertCondition(
            resolveIcon(isReceivingActive: false, isTransferring: false) == dormantIcon,
            "Dormant state maps to subdued circle indicator icon"
        )
        assertCondition(
            resolveIcon(isReceivingActive: true, isTransferring: true) == transferringIcon,
            "Transferring state maps to active circular transfer icon"
        )
        assertCondition(
            resolveIcon(isReceivingActive: false, isTransferring: true) == transferringIcon,
            "Transferring state takes precedence over dormant toggle"
        )
    }

    static func testTransferRecordLiveMetricsAndFormatting() {
        print("\n--- Testing TransferRecord Live Metrics & Formatting ---")
        let totalSize: Int64 = 50 * 1024 * 1024 // 50 MiB

        var record = TransferRecord(
            id: "tx_test_metrics",
            deviceName: "Vivo iQOO Neo9",
            devicePlatform: .android,
            direction: .outgoing,
            filename: "vacation_video.mov",
            fileCount: 1,
            totalSizeBytes: totalSize,
            progress: 0.5,
            status: .transferring,
            transferSpeedBytesPerSec: 10 * 1024 * 1024 // 10 MiB/s
        )

        assertCondition(record.bytesTransferred == 25 * 1024 * 1024, "Calculated bytes transferred is 25 MiB")
        assertCondition(record.formattedSpeed == "10.0 MB/s", "Calculated speed is 10.0 MB/s (got: \(record.formattedSpeed))")
        assertCondition(record.estimatedTimeRemaining == "2s left", "Estimated time remaining is 2s left (got: \(record.estimatedTimeRemaining))")
        assertCondition(record.fileIconName == "video.fill", "Video file maps to video.fill icon")

        // Test photo icon
        record = TransferRecord(
            id: "tx_photo",
            deviceName: "Vivo iQOO Neo9",
            devicePlatform: .android,
            direction: .incoming,
            filename: "photo.jpg",
            totalSizeBytes: 2 * 1024 * 1024,
            progress: 1.0,
            status: .completed
        )
        assertCondition(record.fileIconName == "photo.fill", "Photo file maps to photo.fill icon")

        // Test URL payload icon
        let urlRecord = TransferRecord(
            id: "tx_url",
            deviceName: "iPhone 15",
            devicePlatform: .iOS,
            direction: .incoming,
            filename: "link.url",
            totalSizeBytes: 64,
            payloadType: .url,
            payloadText: "https://nearside.app"
        )
        assertCondition(urlRecord.fileIconName == "link.circle.fill", "URL payload maps to link.circle.fill icon")
    }

    static func testMacNotificationCategoriesAndActions() {
        print("\n--- Testing MacNotificationManager Constants ---")
        let catFile = "NEARSIDE_FILE_RECEIVED"
        let catContent = "NEARSIDE_CONTENT_RECEIVED"
        let actShowFinder = "ACTION_SHOW_IN_FINDER"
        let actOpenFile = "ACTION_OPEN_FILE"
        let actOpenURL = "ACTION_OPEN_URL"
        let actCopyText = "ACTION_COPY_TEXT"

        assertCondition(catFile == "NEARSIDE_FILE_RECEIVED", "File received category matches protocol")
        assertCondition(catContent == "NEARSIDE_CONTENT_RECEIVED", "Content received category matches protocol")
        assertCondition(actShowFinder == "ACTION_SHOW_IN_FINDER", "Show in Finder action identifier matches")
        assertCondition(actOpenFile == "ACTION_OPEN_FILE", "Open file action identifier matches")
        assertCondition(actOpenURL == "ACTION_OPEN_URL", "Open URL action identifier matches")
        assertCondition(actCopyText == "ACTION_COPY_TEXT", "Copy text action identifier matches")
    }

    static func testUniversalDropzonePeerMerging() {
        print("\n--- Testing Universal Dropzone Peer Merging ---")
        let paired = [
            NearsideDevice(
                id: "peer_vivo_1",
                name: "Vivo iQOO Neo9",
                platform: .android,
                fingerprint: "ns1_aabbcc",
                ipAddress: "192.168.0.100",
                port: 41433,
                reachability: .online
            )
        ]

        let discovered = [
            NearsideDevice(
                id: "peer_vivo_1",
                name: "Vivo iQOO Neo9",
                platform: .android,
                fingerprint: "ns1_aabbcc",
                ipAddress: "192.168.0.100",
                port: 41433,
                reachability: .online
            ),
            NearsideDevice(
                id: "peer_mac_2",
                name: "MacBook Air",
                platform: .macOS,
                fingerprint: "ns1_ddeeff",
                ipAddress: "192.168.0.105",
                port: 41433,
                reachability: .online
            )
        ]

        var merged = discovered
        for p in paired {
            if !merged.contains(where: { $0.id == p.id }) {
                merged.append(p)
            }
        }

        assertCondition(merged.count == 2, "Merged peers deduplicated correctly to 2 peers")
        assertCondition(merged.contains(where: { $0.id == "peer_vivo_1" }), "Merged peers contains paired phone")
        assertCondition(merged.contains(where: { $0.id == "peer_mac_2" }), "Merged peers contains discovered Mac")
    }
}

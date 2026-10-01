import Foundation
import Combine
import SwiftUI

@MainActor
public final class AppState: ObservableObject {
    public static let shared = AppState()

    @Published public var localDeviceName: String
    @Published public var localFingerprint: String
    @Published public var isReceivingActive: Bool = true
    @Published public var autoAcceptFromPaired: Bool = true
    @Published public var downloadsFolderURL: URL
    @Published public var pairedDevices: [NearsideDevice] = []
    @Published public var discoveredDevices: [NearsideDevice] = []
    @Published public var transferHistory: [TransferRecord] = []
    @Published public var activeTransfer: TransferRecord?

    public init() {
        let hostName = Host.current().localizedName ?? "MacBook Pro"
        self.localDeviceName = hostName
        self.localFingerprint = "ns1_7a3f8902bc114d6e9021aabbccddeeff"
        self.downloadsFolderURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")

        loadInitialSeedData()
    }

    private func loadInitialSeedData() {
        // Paired devices initial body seed
        self.pairedDevices = [
            NearsideDevice(
                id: "dev_iqoo_neo9",
                name: "iQOO Neo9",
                platform: .android,
                fingerprint: "ns1_8b31f0e2a45c7198bb4d1938fe76d029",
                ipAddress: "192.168.0.101",
                port: 41433,
                reachability: .online,
                lastSeen: Date()
            ),
            NearsideDevice(
                id: "dev_ipad_pro",
                name: "iPad Air",
                platform: .iOS,
                fingerprint: "ns1_c5e891b00142fa9166da23491f08cb34",
                ipAddress: "192.168.0.108",
                port: 41433,
                reachability: .unreachable,
                lastSeen: Date().addingTimeInterval(-86400 * 2)
            )
        ]

        // Discovered nearby peers
        self.discoveredDevices = [
            NearsideDevice(
                id: "dev_iqoo_neo9",
                name: "iQOO Neo9",
                platform: .android,
                fingerprint: "ns1_8b31f0e2a45c7198bb4d1938fe76d029",
                ipAddress: "192.168.0.101",
                port: 41433,
                reachability: .online,
                lastSeen: Date()
            )
        ]

        // Transfer history initial body seed
        self.transferHistory = [
            TransferRecord(
                id: "tx_001",
                deviceName: "iQOO Neo9",
                devicePlatform: .android,
                direction: .outgoing,
                filename: "presentation_final.pdf",
                fileCount: 1,
                totalSizeBytes: 14_850_000,
                progress: 1.0,
                status: .completed,
                timestamp: Date().addingTimeInterval(-1800)
            ),
            TransferRecord(
                id: "tx_002",
                deviceName: "iQOO Neo9",
                devicePlatform: .android,
                direction: .incoming,
                filename: "IMG_20261001_214530.jpg",
                fileCount: 4,
                totalSizeBytes: 38_200_000,
                progress: 1.0,
                status: .completed,
                timestamp: Date().addingTimeInterval(-7200)
            )
        ]
    }

    public func toggleReceiving() {
        isReceivingActive.toggle()
    }

    public func unpairDevice(id: String) {
        pairedDevices.removeAll { $0.id == id }
    }

    public func removeTransferRecord(id: String) {
        transferHistory.removeAll { $0.id == id }
    }

    public func clearHistory() {
        transferHistory.removeAll()
    }

    public func simulateOutgoingTransfer(to device: NearsideDevice, filenames: [String], totalBytes: Int64) {
        let firstFilename = filenames.first ?? "Untitled File"
        let newRecord = TransferRecord(
            deviceName: device.name,
            devicePlatform: device.platform,
            direction: .outgoing,
            filename: firstFilename,
            fileCount: filenames.count,
            totalSizeBytes: totalBytes,
            progress: 0.1,
            status: .transferring,
            timestamp: Date()
        )
        self.activeTransfer = newRecord

        // Simulate streaming progress smoothly
        Task {
            for step in 1...10 {
                try? await Task.sleep(nanoseconds: 200_000_000)
                await MainActor.run {
                    self.activeTransfer?.progress = Double(step) / 10.0
                }
            }
            await MainActor.run {
                if var finished = self.activeTransfer {
                    finished.status = .completed
                    finished.progress = 1.0
                    self.transferHistory.insert(finished, at: 0)
                }
                self.activeTransfer = nil
            }
        }
    }
}

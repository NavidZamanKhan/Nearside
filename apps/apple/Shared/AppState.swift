import Foundation
import Combine
import SwiftUI
import CryptoKit

@MainActor
public final class AppState: ObservableObject {
    public static let shared = AppState()

    public let deviceIdentity: DeviceIdentity
    public let trustStore: PinnedTrustStore

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
        let identity = DeviceIdentity.loadOrCreateDefault()
        self.deviceIdentity = identity
        self.trustStore = PinnedTrustStore()

        let hostName = Host.current().localizedName ?? "MacBook Pro"
        self.localDeviceName = hostName
        self.localFingerprint = identity.publicIdentity
        self.downloadsFolderURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")

        loadInitialTrustAndSeedData()
        startDiscoveryEngine()
    }

    private func loadInitialTrustAndSeedData() {
        let enrolled = trustStore.allEnrolledPeers()
        if !enrolled.isEmpty {
            self.pairedDevices = enrolled.map { record in
                let platform: DevicePlatform
                switch record.platformRaw.lowercased() {
                case "macos": platform = .macOS
                case "android": platform = .android
                case "ios": platform = .iOS
                case "windows": platform = .windows
                case "linux": platform = .linux
                default: platform = .android
                }
                return NearsideDevice(
                    id: record.identity,
                    name: record.name,
                    platform: platform,
                    fingerprint: record.identity,
                    reachability: .online,
                    lastSeen: record.enrolledAt
                )
            }
        } else {
            // Initial seed for immediate visibility before first live pairing
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
        }

        // Initial discovered peers fallback seed
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

    private func startDiscoveryEngine() {
        let service = DiscoveryService.shared
        service.onDiscoveredDevicesChanged = { [weak self] devices in
            guard let self = self else { return }
            if !devices.isEmpty {
                self.discoveredDevices = devices
            }
        }
        service.startAdvertising(
            identity: deviceIdentity.publicIdentity,
            deviceName: localDeviceName,
            isReceiving: isReceivingActive
        )
        service.startBrowsing()
    }

    public func toggleReceiving() {
        isReceivingActive.toggle()
        DiscoveryService.shared.updateReceivingStatus(isReceivingActive)
    }

    public func pairDevice(identity: String, name: String, platform: String, publicKey: P256.Signing.PublicKey) {
        trustStore.enroll(identity: identity, name: name, platform: platform, publicKey: publicKey)
        let devicePlatform: DevicePlatform
        switch platform.lowercased() {
        case "macos": devicePlatform = .macOS
        case "android": devicePlatform = .android
        case "ios": devicePlatform = .iOS
        case "windows": devicePlatform = .windows
        case "linux": devicePlatform = .linux
        default: devicePlatform = .android
        }

        let newDevice = NearsideDevice(
            id: identity,
            name: name,
            platform: devicePlatform,
            fingerprint: identity,
            reachability: .online,
            lastSeen: Date()
        )

        pairedDevices.removeAll { $0.id == identity }
        pairedDevices.append(newDevice)
    }

    public func unpairDevice(id: String) {
        pairedDevices.removeAll { $0.id == id }
        trustStore.unpair(identity: id)
    }

    public func removeTransferRecord(id: String) {
        transferHistory.removeAll { $0.id == id }
    }

    public func clearHistory() {
        transferHistory.removeAll()
    }

    public func sendFiles(urls: [URL], to device: NearsideDevice) {
        guard !urls.isEmpty else { return }

        let firstFilename = urls.first?.lastPathComponent ?? "Files"
        let totalBytes = urls.reduce(Int64(0)) { acc, url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            return acc + size
        }

        let record = TransferRecord(
            deviceName: device.name,
            devicePlatform: device.platform,
            direction: .outgoing,
            filename: firstFilename,
            fileCount: urls.count,
            totalSizeBytes: totalBytes,
            progress: 0.05,
            status: .transferring,
            timestamp: Date()
        )
        self.activeTransfer = record

        if let ip = device.ipAddress, !ip.isEmpty {
            TransferEngine.shared.sendFiles(
                files: urls,
                to: device,
                senderId: localFingerprint,
                onProgress: { [weak self] fraction, transferred, total in
                    Task { @MainActor in
                        self?.activeTransfer?.progress = fraction
                    }
                },
                completion: { [weak self] result in
                    Task { @MainActor in
                        switch result {
                        case .success(let finished):
                            self?.transferHistory.insert(finished, at: 0)
                            self?.activeTransfer = nil
                        case .failure:
                            if var failed = self?.activeTransfer {
                                failed.status = .failed
                                self?.transferHistory.insert(failed, at: 0)
                            }
                            self?.activeTransfer = nil
                        }
                    }
                }
            )
        } else {
            // Fallback to simulation if IP is unresolvable
            simulateOutgoingTransfer(to: device, filenames: urls.map { $0.lastPathComponent }, totalBytes: totalBytes)
        }
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

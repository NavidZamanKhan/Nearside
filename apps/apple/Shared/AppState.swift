import Foundation
import Combine
import SwiftUI
import CryptoKit
#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

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
    @Published public var latestReceivedText: String?
    @Published public var clipboardToastMessage: String?
    @Published public var activePairingPayload: QRPairingPayload?
    @Published public var pairingStatusMessage: String?

    public init(deviceIdentity: DeviceIdentity? = nil, trustStore: PinnedTrustStore? = nil,
        startsDiscovery: Bool = true) {
        let identity = deviceIdentity ?? DeviceIdentity.loadOrCreateDefault()
        self.deviceIdentity = identity
        self.trustStore = trustStore ?? PinnedTrustStore()

#if os(macOS)
        let hostName = Host.current().localizedName ?? "MacBook Pro"
        self.downloadsFolderURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Downloads")
#elseif os(iOS)
        let hostName = UIDevice.current.name
        self.downloadsFolderURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
#else
        let hostName = "Apple Device"
        self.downloadsFolderURL = URL(fileURLWithPath: NSHomeDirectory())
#endif
        self.localDeviceName = hostName
        self.localFingerprint = identity.publicIdentity

        loadInitialTrustAndSeedData()
        if startsDiscovery { startDiscoveryEngine() }
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
                    ipAddress: record.lastKnownIp,
                    port: record.lastKnownPort,
                    reachability: .unreachable,
                    lastSeen: record.enrolledAt
                )
            }
        } else {
            self.pairedDevices = []
        }

        self.discoveredDevices = []
        self.transferHistory = []
    }

    public func startDiscoveryEngine() {
        let service = DiscoveryService.shared
        service.onDiscoveredDevicesChanged = { [weak self] devices in
            guard let self = self else { return }
            self.updateDiscoveryPresence(devices)
        }
        service.onInboundConnection = { [weak self] connection in
            guard let self = self else { return }
            var inboundTransferId: String?
            TransferEngine.shared.handleInboundConnection(
                connection: connection,
                trustStore: self.trustStore,
                deviceIdentity: self.deviceIdentity,
                destinationFolder: self.downloadsFolderURL,
                onProgress: { fraction, record in
                    inboundTransferId = record.id
                    Task { @MainActor in
                        self.activeTransfer = record
                        #if os(macOS)
                        StatusItemController.shared.updateStatusIcon(isReceivingActive: self.isReceivingActive, isTransferring: true)
                        #endif
                    }
                },
                onComplete: { result in
                    let completedTransferId = inboundTransferId
                    Task { @MainActor in
                        defer {
                            #if os(macOS)
                            StatusItemController.shared.updateStatusIcon(isReceivingActive: self.isReceivingActive,
                                isTransferring: self.activeTransfer != nil)
                            #endif
                        }
                        switch result {
                        case .success(let finished):
                            if finished.id.hasPrefix("pair_"), finished.fileCount == 0 {
                                self.recordPairingSuccess(sessionId: String(finished.id.dropFirst("pair_".count)),
                                    peerName: finished.deviceName)
                                return
                            }
                            self.transferHistory.insert(finished, at: 0)
                            self.activeTransfer = nil
                            if finished.payloadType == .text || finished.payloadType == .url {
                                self.latestReceivedText = finished.payloadText
                                self.clipboardToastMessage = (finished.payloadType == .url) ? "Received link copied to clipboard" : "Received text copied to clipboard"
                            }
                            #if os(macOS)
                            MacNotificationManager.shared.notifyTransferComplete(record: finished, downloadsURL: self.downloadsFolderURL)
                            #elseif os(iOS)
                            IOSNotificationManager.shared.notifyTransferComplete(record: finished, downloadsURL: self.downloadsFolderURL)
                            #endif
                        case .failure(let error):
                            self.recordInboundFailure(error, transferId: completedTransferId)
                        }
                    }
                }
            )
        }
        service.startAdvertising(
            identity: deviceIdentity.publicIdentity,
            deviceName: localDeviceName,
            isReceiving: isReceivingActive
        )
        if isReceivingActive {
            service.startBrowsing()
        }
    }

    public func toggleReceiving() {
        isReceivingActive.toggle()
        DiscoveryService.shared.updateReceivingStatus(isReceivingActive)
        #if os(macOS)
        StatusItemController.shared.updateStatusIcon(isReceivingActive: isReceivingActive, isTransferring: activeTransfer != nil)
        #endif
    }

    public func cancelActiveTransfer() {
        guard let active = activeTransfer else { return }
        TransferEngine.shared.cancelTransfer(id: active.id)
        var cancelled = active
        cancelled.status = .cancelled
        cancelled.errorCode = NearsideErrorCode.transferCancelled.rawValue
        cancelled.errorMessage = "Transfer cancelled by user"
        transferHistory.insert(cancelled, at: 0)
        activeTransfer = nil
        #if os(macOS)
        StatusItemController.shared.updateStatusIcon(isReceivingActive: isReceivingActive, isTransferring: false)
        #endif
    }

    public func cancelTransfer(id: String) {
        cancelActiveTransfer()
    }

    public func pairDevice(identity: String, name: String, platform: String, publicKey: P256.Signing.PublicKey) {
        do {
            try trustStore.enrollVerifiedPeer(identity: identity, name: name, platform: platform, publicKey: publicKey)
            refreshTrustedDevices()
        } catch {
            let failure = (error as? NearsideError) ?? NearsideError(code: .trustStorageFailed,
                operation: "pairDevice", message: "Could not save verified peer enrollment", underlyingError: error)
            NearsideLogger.shared.error(failure, state: "failed")
        }
    }

    public func startPairingSession(expectedPeerIdentity: String? = nil) -> QRPairingPayload? {
        stopPairingSession()
        guard isReceivingActive else {
            pairingStatusMessage = "Turn on Receiving to display a pairing QR."
            return nil
        }
        let payload = QRPairingPayload(hostIdentity: localFingerprint, hostName: localDeviceName)
        QRPairingSessions.shared.register(payload, expectedClientIdentity: expectedPeerIdentity)
        activePairingPayload = payload
        pairingStatusMessage = nil
        return payload
    }

    public func stopPairingSession(expectedSessionId: String? = nil) {
        if let expectedSessionId, activePairingPayload?.sessionId != expectedSessionId { return }
        if let payload = activePairingPayload { QRPairingSessions.shared.unregister(payload.sessionId) }
        activePairingPayload = nil
    }

    func recordPairingSuccess(sessionId: String, peerName: String) {
        refreshTrustedDevices()
        let message = "Paired with \(peerName)"
        clipboardToastMessage = message
        guard activePairingPayload?.sessionId == sessionId else { return }
        pairingStatusMessage = message
        QRPairingSessions.shared.unregister(sessionId)
        activePairingPayload = nil
    }

    func recordPairingFailure(_ failure: NearsideError) {
        guard let payload = activePairingPayload, failure.correlationId == payload.sessionId else { return }
        pairingStatusMessage = "Pairing failed [\(failure.code.rawValue)]. Display a fresh QR code and retry."
    }

    func recordInboundFailure(_ error: Error, transferId: String?) {
        let failure = (error as? NearsideError)
            ?? (error as? TransferEngineError)?.toNearsideError(operation: "handleInboundConnection")
            ?? NearsideError(code: .transferInterrupted, operation: "handleInboundConnection",
                message: "Incoming transfer failed", underlyingError: error)
        NearsideLogger.shared.error(failure, state: "failed")
        recordPairingFailure(failure)
        // A QR exchange has no transfer progress and cannot fail another connection's file.
        guard let transferId, var failed = activeTransfer, failed.id == transferId else { return }
        failed.status = .failed
        failed.errorCode = failure.code.rawValue
        failed.errorMessage = failure.message
        failed.correlationId = failed.id
        transferHistory.insert(failed, at: 0)
        activeTransfer = nil
    }

    public func pairWithQrPayload(_ payload: QRPairingPayload, expectedIdentity: String? = nil,
        completion: ((Result<NearsideDevice, Error>) -> Void)? = nil) {
        do { try payload.validateSelectedHost(expectedIdentity, localIdentity: deviceIdentity.publicIdentity) }
        catch {
            if let failure = error as? NearsideError { NearsideLogger.shared.error(failure, state: "rejected") }
            completion?(.failure(error))
            return
        }
        let live = DiscoveryService.shared.findDiscoveredDevice(identity: payload.hostIdentity)
        guard let host = live?.ipAddress ?? payload.ip, !host.isEmpty else {
            let error = NearsideError(code: .discoveryResolveFailed, operation: "pairQR",
                message: "Pairing device is not currently discoverable", correlationId: payload.sessionId)
            NearsideLogger.shared.error(error, state: "failed")
            completion?(.failure(error))
            return
        }
        let port = live?.port ?? UInt16(exactly: payload.port ?? 41433) ?? 41433
        pairWithPeerAddress(host: host, port: port, qrPayload: payload, completion: completion)
    }

    public func pairWithPeerAddress(host: String, port: UInt16 = 41433, confirmationCode: String = "", qrPayload: QRPairingPayload? = nil, completion: ((Result<NearsideDevice, Error>) -> Void)? = nil) {
        TransferEngine.shared.initiatePairing(
            to: host,
            port: port,
            confirmationCode: confirmationCode,
            deviceIdentity: self.deviceIdentity,
            deviceName: self.localDeviceName,
            trustStore: self.trustStore,
            qrPayload: qrPayload
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let resp):
                    self.refreshTrustedDevices()
                    guard let newDevice = self.pairedDevices.first(where: { $0.fingerprint == resp.serverId }),
                          self.trustStore.canTransfer(identity: resp.serverId) else {
                        completion?(.failure(NearsideError(code: .trustStorageFailed, operation: "pairQR",
                            message: "Verified peer enrollment was not saved", correlationId: qrPayload?.sessionId)))
                        return
                    }
                    completion?(.success(newDevice))
                case .failure(let error):
                    let failure = (error as? NearsideError) ?? NearsideError(code: .pairingVerificationFailed,
                        operation: "pairQR", message: "Pairing verification failed. Display a fresh QR code and retry.",
                        underlyingError: error, correlationId: qrPayload?.sessionId)
                    NearsideLogger.shared.error(failure, state: "failed")
                    completion?(.failure(failure))
                }
            }
        }
    }

    public var availableNearbyDevices: [NearsideDevice] {
        PeerPresenceSnapshot(trustedDevices: pairedDevices, discoveredDevices: discoveredDevices).availableNearbyDevices
    }

    public var onlineTransferRecipients: [NearsideDevice] {
        pairedDevices.filter { $0.reachability == .online && trustStore.canTransfer(identity: $0.fingerprint) }
    }

    public func updateDiscoveryPresence(_ devices: [NearsideDevice]) {
        let snapshot = PeerPresenceSnapshot(trustedDevices: pairedDevices, discoveredDevices: devices)
        pairedDevices = snapshot.trustedDevices
        discoveredDevices = snapshot.discoveredDevices
    }

    /// Called after enrollment so a completed handshake cannot invent ongoing discovery presence.
    public func refreshTrustedDevices() {
        pairedDevices = trustStore.allEnrolledPeers().map { record in
            let platform = DevicePlatform(rawValue: record.platformRaw.lowercased()) ?? .android
            return NearsideDevice(id: record.identity, name: record.name, platform: platform,
                fingerprint: record.identity, ipAddress: record.lastKnownIp, port: record.lastKnownPort,
                reachability: .unreachable, lastSeen: record.enrolledAt)
        }
        updateDiscoveryPresence(discoveredDevices)
    }

    @discardableResult
    public func unpairDevice(id: String) -> Result<Void, Error> {
        let correlationId = UUID().uuidString
        do {
            try trustStore.unpairPersisted(identity: id)
            refreshTrustedDevices()
            clipboardToastMessage = "Device unpaired"
            return .success(())
        } catch {
            let failure = NearsideError(code: .trustStorageFailed, operation: "unpairDevice",
                message: "Could not save trust removal. The device is still paired; retry after checking storage access.",
                underlyingError: error, correlationId: correlationId)
            NearsideLogger.shared.error(failure, state: "failed")
            clipboardToastMessage = "Unpair failed [\(failure.code.rawValue)]. The device is still paired."
            return .failure(failure)
        }
    }

    public func removeTransferRecord(id: String) {
        transferHistory.removeAll { $0.id == id }
    }

    public func clearHistory() {
        transferHistory.removeAll()
    }

    public func sendFiles(urls: [URL], to device: NearsideDevice) {
        guard !urls.isEmpty else { return }

        let targetDevice = device
        guard trustStore.canTransfer(identity: device.fingerprint) else {
            let error = NearsideError(code: trustStore.isBlocked(identity: device.fingerprint) ? .trustPeerBlocked : .trustUntrustedPeer,
                operation: "sendFiles", message: "Pair the selected device before sending")
            NearsideLogger.shared.error(error, state: "rejected")
            return
        }

        let firstFilename = urls.first?.lastPathComponent ?? "Files"
        let totalBytes = urls.reduce(Int64(0)) { acc, url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            return acc + size
        }

        let record = TransferRecord(
            deviceName: targetDevice.name,
            devicePlatform: targetDevice.platform,
            direction: .outgoing,
            filename: firstFilename,
            fileCount: urls.count,
            totalSizeBytes: totalBytes,
            progress: 0.05,
            status: .transferring,
            timestamp: Date()
        )
        self.activeTransfer = record

        do {
            DiscoveryService.shared.ensureBrowsingActive()
            var lastSampleTime = Date()
            var lastSampleBytes: Int64 = 0

            TransferEngine.shared.sendFiles(
                files: urls,
                to: targetDevice,
                senderId: deviceIdentity.publicIdentity,
                trustStore: trustStore,
                deviceIdentity: deviceIdentity,
                onProgress: { [weak self] fraction, transferred, total in
                    Task { @MainActor in
                        let now = Date()
                        let elapsed = now.timeIntervalSince(lastSampleTime)
                        if elapsed >= 0.25 {
                            let bytesDelta = transferred - lastSampleBytes
                            let currentSpeed = Double(bytesDelta) / elapsed
                            self?.activeTransfer?.transferSpeedBytesPerSec = max(0, currentSpeed)
                            lastSampleBytes = transferred
                            lastSampleTime = now
                        }
                        self?.activeTransfer?.progress = fraction
                        #if os(macOS)
                        StatusItemController.shared.updateStatusIcon(isReceivingActive: self?.isReceivingActive ?? true, isTransferring: true)
                        #endif
                    }
                },
                completion: { [weak self] result in
                    Task { @MainActor in
                        #if os(macOS)
                        StatusItemController.shared.updateStatusIcon(isReceivingActive: self?.isReceivingActive ?? true, isTransferring: false)
                        #endif
                        switch result {
                        case .success(let finished):
                            self?.transferHistory.insert(finished, at: 0)
                            self?.activeTransfer = nil
                        case .failure(let error):
                            let nsErr = (error as? NearsideError) ?? (error as? TransferEngineError)?.toNearsideError(operation: "sendFiles") ?? NearsideError(code: .transferInterrupted, operation: "sendFiles", message: error.localizedDescription, underlyingError: error)
                            NearsideLogger.shared.error(nsErr, state: "failed")
                            if var failed = self?.activeTransfer {
                                failed.status = .failed
                                failed.errorCode = nsErr.code.rawValue
                                failed.errorMessage = nsErr.message
                                failed.correlationId = failed.id
                                self?.transferHistory.insert(failed, at: 0)
                            }
                            self?.activeTransfer = nil
                        }
                    }
                }
            )
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

    public func sendClipboard(to device: NearsideDevice) {
        guard trustStore.canTransfer(identity: device.fingerprint) else {
            NearsideLogger.shared.error(NearsideError(code: trustStore.isBlocked(identity: device.fingerprint) ? .trustPeerBlocked : .trustUntrustedPeer,
                operation: "sendClipboard", message: "Pair the selected device before sending"), state: "rejected")
            return
        }
        let text: String?
        #if os(macOS)
        text = NSPasteboard.general.string(forType: .string)
        #elseif os(iOS)
        text = UIPasteboard.general.string
        #else
        text = nil
        #endif

        guard let payload = text, !payload.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.clipboardToastMessage = "Clipboard is empty"
            Task {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self.clipboardToastMessage = nil
            }
            return
        }

        let isURL = payload.hasPrefix("http://") || payload.hasPrefix("https://")
        let displayFilename = isURL ? payload : (payload.count > 25 ? String(payload.prefix(25)) + "..." : payload)

        let record = TransferRecord(
            deviceName: device.name,
            devicePlatform: device.platform,
            direction: .outgoing,
            filename: displayFilename,
            fileCount: 1,
            totalSizeBytes: Int64(payload.utf8.count),
            progress: 0.05,
            status: .transferring,
            timestamp: Date(),
            payloadType: isURL ? .url : .text,
            payloadText: payload
        )
        self.activeTransfer = record

        do {
            TransferEngine.shared.sendText(
                text: payload,
                isURL: isURL,
                to: device,
                senderId: deviceIdentity.publicIdentity,
                trustStore: trustStore,
                deviceIdentity: deviceIdentity,
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
        }
    }
}

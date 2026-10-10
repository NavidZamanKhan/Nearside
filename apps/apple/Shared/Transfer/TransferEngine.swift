import Foundation
import Network
import CryptoKit
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

public enum TransferEngineError: Error, LocalizedError {
    case connectionFailed(String)
    case untrustedPeer(String)
    case manifestRejected(String)
    case integrityMismatch(String)
    case fileAccessError(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .connectionFailed(let msg): return "Connection failed: \(msg)"
        case .untrustedPeer(let msg): return "Untrusted peer: \(msg)"
        case .manifestRejected(let msg): return "Transfer rejected: \(msg)"
        case .integrityMismatch(let msg): return "Integrity error: \(msg)"
        case .fileAccessError(let msg): return "File error: \(msg)"
        case .cancelled: return "Transfer was cancelled"
        }
    }

    public func toNearsideError(operation: String = "transfer", correlationId: String? = nil, retryCount: Int? = nil) -> NearsideError {
        switch self {
        case .connectionFailed(let msg):
            return NearsideError(code: .connectionTimedOut, operation: operation, message: msg, underlyingError: self, correlationId: correlationId, retryCount: retryCount)
        case .untrustedPeer(let peer):
            return NearsideError(code: .trustUntrustedPeer, operation: operation, message: "Peer \(NearsideRedactor.sanitizeIdentity(peer)) is untrusted", underlyingError: self, correlationId: correlationId, retryCount: retryCount)
        case .manifestRejected(let reason):
            return NearsideError(code: .transferRejected, operation: operation, message: reason, underlyingError: self, correlationId: correlationId, retryCount: retryCount)
        case .integrityMismatch(let item):
            return NearsideError(code: .verifyFileChecksumMismatch, operation: operation, message: "Checksum mismatch for \(item)", underlyingError: self, correlationId: correlationId, retryCount: retryCount)
        case .fileAccessError(let msg):
            return NearsideError(code: .storageReadFailed, operation: operation, message: msg, underlyingError: self, correlationId: correlationId, retryCount: retryCount)
        case .cancelled:
            return NearsideError(code: .transferCancelled, operation: operation, message: "Transfer was cancelled", underlyingError: self, correlationId: correlationId, retryCount: retryCount)
        }
    }
}

public struct RetryPolicy: Sendable {
    public let maxAttempts: Int
    public let initialDelay: TimeInterval
    public let multiplier: Double

    public static let `default` = RetryPolicy(maxAttempts: 3, initialDelay: 0.5, multiplier: 2.0)

    public init(maxAttempts: Int = 3, initialDelay: TimeInterval = 0.5, multiplier: Double = 2.0) {
        precondition((1...10).contains(maxAttempts) && initialDelay.isFinite && (0...30).contains(initialDelay) && multiplier.isFinite && multiplier >= 1)
        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
        self.multiplier = multiplier
    }

    public func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        return min(30, initialDelay * pow(multiplier, Double(attempt - 1)))
    }
}

enum PeerEndpointRecovery {
    static func endpoint(for device: NearsideDevice, live: NWEndpoint?) -> NWEndpoint? {
        guard device.id == device.fingerprint else { return nil }
        if let live = live { return live }
        guard let address = device.ipAddress, !address.isEmpty,
              let port = NWEndpoint.Port(rawValue: device.port ?? 41433), port.rawValue > 0 else { return nil }
        if address.hasPrefix("Nearside-") || (!address.contains(".") && !address.contains(":")) {
            return .service(name: address, type: "_nearside._tcp", domain: "local.", interface: nil)
        }
        return .hostPort(host: NWEndpoint.Host(address), port: port)
    }

    static func shouldRetry(error: Error, attempt: Int, policy: RetryPolicy) -> Bool {
        guard attempt < policy.maxAttempts else { return false }
        if let transferError = error as? TransferEngineError, case .connectionFailed = transferError { return true }
        if let error = error as? NearsideError {
            return [.connectionTimedOut, .connectionRefused, .connectionClosed, .transferInterrupted].contains(error.code)
        }
        return error is NWError
    }
}

public final class TransferEngine: @unchecked Sendable {
    public static let shared = TransferEngine()

    private let queue = DispatchQueue(label: "com.nearside.transfer", qos: .userInitiated)
    private var activeConnections: [String: NWConnection] = [:]

    public init() {}

    public func buildManifest(for files: [URL], senderId: String) throws -> (manifest: TransferManifest, fileHandles: [FileHandle]) {
        var items: [TransferItemManifest] = []
        var handles: [FileHandle] = []

        for (index, fileURL) in files.enumerated() {
            let handle = try FileHandle(forReadingFrom: fileURL)
            handles.append(handle)

            var hasher = SHA256()
            var fileSize: Int64 = 0
            while true {
                let chunk = handle.readData(ofLength: TransferChunk.maxChunkSize)
                if chunk.isEmpty { break }
                hasher.update(data: chunk)
                fileSize += Int64(chunk.count)
            }
            try handle.seek(toOffset: 0)

            let ext = fileURL.pathExtension.lowercased()
            let mimeType: String
            if ext == "txt" || ext == "md" || ext == "json" {
                mimeType = "text/plain"
            } else if ext == "url" {
                mimeType = "text/uri-list"
            } else {
                mimeType = "application/octet-stream"
            }

            let shaHex = hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
            let item = TransferItemManifest(
                index: index,
                name: fileURL.lastPathComponent,
                mimeType: mimeType,
                size: fileSize,
                sha256: shaHex
            )
            items.append(item)
        }

        let manifest = TransferManifest(
            transferId: "tx_\(UUID().uuidString.prefix(12).lowercased())",
            senderId: senderId,
            items: items
        )
        return (manifest, handles)
    }

    public func sendText(
        text: String,
        isURL: Bool = false,
        to device: NearsideDevice,
        senderId: String,
        retryPolicy: RetryPolicy = .default,
        trustStore: PinnedTrustStore? = nil,
        onProgress: @escaping (Double, Int64, Int64) -> Void,
        completion: @escaping (Result<TransferRecord, Error>) -> Void
    ) {
        let tempFileName = isURL ? "link.url" : "clipboard.txt"
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("nearside_text_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let tempFile = tempDir.appendingPathComponent(tempFileName)

        do {
            try text.write(to: tempFile, atomically: true, encoding: .utf8)
        } catch {
            completion(.failure(TransferEngineError.fileAccessError("Failed to stage text payload")))
            return
        }

        sendFiles(
            files: [tempFile],
            to: device,
            senderId: senderId,
            retryPolicy: retryPolicy,
            trustStore: trustStore,
            onProgress: onProgress,
            completion: { result in
                try? FileManager.default.removeItem(at: tempDir)
                switch result {
                case .success(var record):
                    record.payloadType = isURL ? .url : .text
                    record.payloadText = text
                    completion(.success(record))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        )
    }

    public func initiatePairing(
        to host: String, port: UInt16 = 41433, confirmationCode: String = "",
        deviceIdentity: DeviceIdentity, deviceName: String, trustStore: PinnedTrustStore,
        qrPayload: QRPairingPayload? = nil,
        completion: @escaping (Result<PairResponseFrame, Error>) -> Void
    ) {
        guard let payload = qrPayload else {
            completion(.failure(NearsideError(code: .pairingVerificationFailed, operation: "initiatePairing",
                message: "Scan or paste a current Nearside QR code to securely pair")))
            return
        }
        guard !payload.isExpired else {
            completion(.failure(PairingError.sessionExpired.toNearsideError(correlationId: payload.sessionId)))
            return
        }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        var finished = false
        var started = false
        func finish(_ result: Result<PairResponseFrame, Error>) {
            guard !finished else { return }; finished = true
            connection.cancel(); completion(result)
        }
        queue.asyncAfter(deadline: .now() + 15) { if !finished { finish(.failure(NearsideError(code: .connectionTimedOut,
            operation: "pairQR", message: "Pairing exchange timed out", correlationId: payload.sessionId))) } }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                guard !started else { return }; started = true
                self.startQRPairClient(connection: connection, identity: deviceIdentity, name: deviceName,
                    payload: payload, trustStore: trustStore, host: host, port: port, finish: finish)
            case .failed(let error): finish(.failure(error))
            default: break
            }
        }
        connection.start(queue: queue)
    }

    public func cancelTransfer(id: String) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if let conn = self.activeConnections.removeValue(forKey: id) {
                conn.cancel()
                NearsideLogger.shared.info("transfer", "cancelTransfer", "Transfer cancelled by user", correlationId: id)
            }
        }
    }

    public func sendFiles(
        files: [URL],
        to device: NearsideDevice,
        senderId: String,
        retryPolicy: RetryPolicy = .default,
        trustStore: PinnedTrustStore? = nil,
        onProgress: @escaping (Double, Int64, Int64) -> Void,
        completion: @escaping (Result<TransferRecord, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self = self else { return }

            if let trustStore = trustStore, !trustStore.canTransfer(identity: device.fingerprint) {
                let code: NearsideErrorCode = trustStore.isBlocked(identity: device.fingerprint) ? .trustPeerBlocked : .trustUntrustedPeer
                completion(.failure(NearsideError(code: code, operation: "sendFiles", message: "Pair the selected peer before sending")))
                return
            }
            DiscoveryService.shared.ensureBrowsingActive()

            let manifest: TransferManifest
            do {
                let res = try self.buildManifest(for: files, senderId: senderId)
                manifest = res.manifest
                for h in res.fileHandles { try? h.close() }
            } catch {
                completion(.failure(TransferEngineError.fileAccessError(error.localizedDescription)))
                return
            }

            let transferId = manifest.transferId
            let isTextOrUrl = files.count == 1 && (files.first?.pathExtension.lowercased() == "txt" || files.first?.pathExtension.lowercased() == "url")
            let initialPayloadType: PayloadType = (files.first?.pathExtension.lowercased() == "url") ? .url : (files.first?.pathExtension.lowercased() == "txt" ? .text : .file)
            var initialPayloadText: String? = nil
            if isTextOrUrl, let firstFile = files.first {
                initialPayloadText = try? String(contentsOf: firstFile, encoding: .utf8)
            }

            let recordTemplate = TransferRecord(
                id: transferId,
                deviceName: device.name,
                devicePlatform: device.platform,
                direction: .outgoing,
                filename: files.first?.lastPathComponent ?? "Files",
                fileCount: files.count,
                totalSizeBytes: manifest.totalBytes,
                progress: 0.0,
                status: .transferring,
                timestamp: Date(),
                payloadType: initialPayloadType,
                payloadText: initialPayloadText,
                correlationId: transferId
            )

            NearsideLogger.shared.info(
                "transfer",
                "sendFiles",
                "Starting outbound transfer with \(files.count) file(s)",
                state: "starting",
                correlationId: transferId,
                metadata: [
                    "totalBytes": "\(manifest.totalBytes)",
                    "destination": NearsideRedactor.sanitizeIdentity(device.fingerprint)
                ]
            )

            func executeAttempt(attempt: Int) {
                // A Bonjour service endpoint resolves fresh addresses on every connection.
                let live = DiscoveryService.shared.discoveredEndpoint(identity: device.fingerprint)
                guard let endpoint = PeerEndpointRecovery.endpoint(for: device, live: live) else {
                    completion(.failure(NearsideError(code: .connectionRefused, operation: "executeAttempt", message: "Selected peer has no live endpoint", correlationId: transferId, retryCount: attempt)))
                    return
                }
                NearsideLogger.shared.debug(
                    "transfer",
                    "executeAttempt",
                    "Beginning connection attempt \(attempt)/\(retryPolicy.maxAttempts)",
                    state: "connecting",
                    correlationId: transferId,
                    metadata: ["attempt": "\(attempt)", "maxAttempts": "\(retryPolicy.maxAttempts)"]
                )

                var handles: [FileHandle] = []
                for fileURL in files {
                    guard let h = try? FileHandle(forReadingFrom: fileURL) else {
                        for opened in handles { try? opened.close() }
                        let err = NearsideError(
                            code: .storageReadFailed,
                            operation: "executeAttempt",
                            message: "Cannot open file: \(fileURL.lastPathComponent)",
                            correlationId: transferId
                        )
                        NearsideLogger.shared.error(err, state: "failed")
                        completion(.failure(err))
                        return
                    }
                    handles.append(h)
                }

                let connection = NWConnection(to: endpoint, using: .tcp)
                self.activeConnections[transferId] = connection

                var hasCompletedOrRetried = false
                let lock = NSLock()

                func handleAttemptFailure(error: Error) {
                    lock.lock()
                    guard !hasCompletedOrRetried else {
                        lock.unlock()
                        return
                    }
                    hasCompletedOrRetried = true
                    lock.unlock()

                    self.activeConnections.removeValue(forKey: transferId)
                    connection.cancel()
                    for h in handles { try? h.close() }

                    if PeerEndpointRecovery.shouldRetry(error: error, attempt: attempt, policy: retryPolicy) {
                        DiscoveryService.shared.ensureBrowsingActive()
                        let delay = retryPolicy.delay(forAttempt: attempt)
                        NearsideLogger.shared.warn(
                            "transfer",
                            "executeAttempt",
                            "Outbound attempt \(attempt) failed, scheduling retry in \(String(format: "%.2f", delay))s",
                            state: "retrying",
                            correlationId: transferId,
                            retryCount: attempt,
                            underlyingError: error,
                            metadata: ["delaySeconds": "\(delay)"]
                        )
                        self.queue.asyncAfter(deadline: .now() + delay) {
                            executeAttempt(attempt: attempt + 1)
                        }
                    } else if PeerEndpointRecovery.shouldRetry(error: error, attempt: 0, policy: retryPolicy) {
                        let finalErr = NearsideError(
                            code: .transferRetryExhausted,
                            operation: "executeAttempt",
                            message: "Outbound transfer exhausted all \(retryPolicy.maxAttempts) attempts",
                            underlyingError: error,
                            correlationId: transferId,
                            retryCount: attempt
                        )
                        NearsideLogger.shared.error(finalErr, state: "failed")
                        completion(.failure(finalErr))
                    } else {
                        completion(.failure(error))
                    }
                }

                var timeoutItem: DispatchWorkItem? = DispatchWorkItem { [weak self] in
                    guard self != nil else { return }
                    handleAttemptFailure(error: TransferEngineError.connectionFailed("Connection timed out after 5 seconds"))
                }
                if let item = timeoutItem {
                    self.queue.asyncAfter(deadline: .now() + 5.0, execute: item)
                }

                connection.stateUpdateHandler = { [weak self] state in
                    guard let self = self else { return }
                    switch state {
                    case .ready:
                        timeoutItem?.cancel()
                        timeoutItem = nil
                        NearsideLogger.shared.info(
                            "connection",
                            "stateUpdate",
                            "TCP connection ready, streaming chunks",
                            state: "transferring",
                            correlationId: transferId
                        )
                        self.performOutboundStream(
                            connection: connection,
                            manifest: manifest,
                            fileHandles: handles,
                            onProgress: onProgress,
                            onComplete: { result in
                                switch result {
                                case .success:
                                    lock.lock()
                                    guard !hasCompletedOrRetried else { lock.unlock(); return }
                                    hasCompletedOrRetried = true
                                    lock.unlock()
                                    self.activeConnections.removeValue(forKey: transferId)
                                    connection.cancel()
                                    for h in handles { try? h.close() }
                                    if case let .hostPort(host, port) = connection.currentPath?.remoteEndpoint {
                                        trustStore?.updatePeerEndpoint(identity: device.fingerprint, ip: "\(host)", port: port.rawValue)
                                    }
                                    var finalRecord = recordTemplate
                                    finalRecord.progress = 1.0
                                    finalRecord.status = .completed
                                    NearsideLogger.shared.info(
                                        "transfer",
                                        "performOutboundStream",
                                        "Outbound transfer completed successfully",
                                        state: "completed",
                                        correlationId: transferId,
                                        metadata: ["totalBytes": "\(manifest.totalBytes)"]
                                    )
                                    completion(.success(finalRecord))
                                case .failure(let err):
                                    handleAttemptFailure(error: err)
                                }
                            }
                        )
                    case .waiting(let err):
                        timeoutItem?.cancel()
                        timeoutItem = nil
                        handleAttemptFailure(error: TransferEngineError.connectionFailed("Peer unreachable: \(err.localizedDescription)"))
                    case .failed(let err):
                        timeoutItem?.cancel()
                        timeoutItem = nil
                        handleAttemptFailure(error: TransferEngineError.connectionFailed(err.localizedDescription))
                    default:
                        break
                    }
                }

                connection.start(queue: self.queue)
            }

            executeAttempt(attempt: 1)
        }
    }

    private func performOutboundStream(
        connection: NWConnection,
        manifest: TransferManifest,
        fileHandles: [FileHandle],
        onProgress: @escaping (Double, Int64, Int64) -> Void,
        onComplete: @escaping (Result<Void, Error>) -> Void
    ) {
        guard let manifestData = try? JSONEncoder().encode(manifest) else {
            onComplete(.failure(TransferEngineError.manifestRejected("Failed to encode manifest")))
            return
        }

        var header = Data()
        var magicBE = TransferChunk.magic.bigEndian
        header.append(Data(bytes: &magicBE, count: 4))
        var type = FrameType.manifest.rawValue
        header.append(Data(bytes: &type, count: 1))
        var lenBE = UInt32(manifestData.count).bigEndian
        header.append(Data(bytes: &lenBE, count: 4))
        header.append(manifestData)

        connection.send(content: header, completion: .contentProcessed { [weak self] error in
            guard let self = self else { return }
            if let error = error {
                onComplete(.failure(TransferEngineError.connectionFailed(error.localizedDescription)))
                return
            }

            self.receiveAck(connection: connection) { ackResult in
                switch ackResult {
                case .success(let ack):
                    guard ack.status == "ACCEPTED" else {
                        onComplete(.failure(TransferEngineError.manifestRejected(ack.status)))
                        return
                    }

                    var remainingResume = ack.bytesReceived
                    var startItem = 0
                    var startOffset: UInt64 = 0
                    for (idx, item) in manifest.items.enumerated() {
                        if remainingResume >= item.size {
                            remainingResume -= item.size
                            startItem = idx + 1
                        } else {
                            startItem = idx
                            startOffset = UInt64(remainingResume)
                            remainingResume = 0
                            break
                        }
                    }

                    self.streamFileChunks(
                        connection: connection,
                        manifest: manifest,
                        fileHandles: fileHandles,
                        startItemIndex: startItem,
                        startOffset: startOffset,
                        initialBytesTransferred: ack.bytesReceived,
                        onProgress: onProgress,
                        onComplete: onComplete
                    )
                case .failure(let err):
                    onComplete(.failure(err))
                }
            }
        })
    }

    private func receiveAck(connection: NWConnection, completion: @escaping (Result<TransferAck, Error>) -> Void) {
        var completed = false
        let lock = NSLock()

        var timerItem: DispatchWorkItem? = DispatchWorkItem {
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            completed = true
            lock.unlock()
            completion(.failure(TransferEngineError.connectionFailed("Target device did not respond within 5s. Ensure Nearside is open and receiving on the device.")))
        }

        if let item = timerItem {
            self.queue.asyncAfter(deadline: .now() + 5.0, execute: item)
        }

        func finish(_ result: Result<TransferAck, Error>) {
            lock.lock()
            guard !completed else {
                lock.unlock()
                return
            }
            completed = true
            timerItem?.cancel()
            timerItem = nil
            lock.unlock()
            completion(result)
        }

        connection.receive(minimumIncompleteLength: 9, maximumLength: 9) { headerData, _, isComplete, error in
            if let error = error {
                finish(.failure(TransferEngineError.connectionFailed(error.localizedDescription)))
                return
            }
            guard let data = headerData, data.count == 9 else {
                finish(.failure(TransferEngineError.connectionFailed("Truncated ACK header")))
                return
            }

            let len = Int(data.subdata(in: 5..<9).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian)
            connection.receive(minimumIncompleteLength: len, maximumLength: len) { payloadData, _, _, ackError in
                if let ackError = ackError {
                    finish(.failure(TransferEngineError.connectionFailed(ackError.localizedDescription)))
                    return
                }
                guard let payload = payloadData,
                      let ack = try? JSONDecoder().decode(TransferAck.self, from: payload) else {
                    finish(.failure(TransferEngineError.connectionFailed("Malformed ACK payload")))
                    return
                }
                finish(.success(ack))
            }
        }
    }

    private func streamFileChunks(
        connection: NWConnection,
        manifest: TransferManifest,
        fileHandles: [FileHandle],
        startItemIndex: Int = 0,
        startOffset: UInt64 = 0,
        initialBytesTransferred: Int64 = 0,
        onProgress: @escaping (Double, Int64, Int64) -> Void,
        onComplete: @escaping (Result<Void, Error>) -> Void
    ) {
        let totalBytes = manifest.totalBytes
        var bytesTransferred: Int64 = initialBytesTransferred

        func sendNextChunk(itemIndex: Int, offset: UInt64) {
            guard itemIndex < fileHandles.count else {
                var completeHeader = Data()
                var magicBE = TransferChunk.magic.bigEndian
                completeHeader.append(Data(bytes: &magicBE, count: 4))
                var type = FrameType.complete.rawValue
                completeHeader.append(Data(bytes: &type, count: 1))
                var zeroLen: UInt32 = 0
                completeHeader.append(Data(bytes: &zeroLen, count: 4))

                connection.send(content: completeHeader, completion: .contentProcessed { error in
                    if let error = error {
                        onComplete(.failure(TransferEngineError.connectionFailed(error.localizedDescription)))
                    } else {
                        onProgress(1.0, totalBytes, totalBytes)
                        onComplete(.success(()))
                    }
                })
                return
            }

            let handle = fileHandles[itemIndex]
            let chunkData = handle.readData(ofLength: TransferChunk.maxChunkSize)

            if chunkData.isEmpty {
                if itemIndex + 1 < fileHandles.count {
                    try? fileHandles[itemIndex + 1].seek(toOffset: 0)
                }
                sendNextChunk(itemIndex: itemIndex + 1, offset: 0)
                return
            }

            let chunk = TransferChunk(itemIndex: UInt32(itemIndex), offset: offset, data: chunkData)
            let packet = chunk.encode()

            connection.send(content: packet, completion: .contentProcessed { error in
                if let error = error {
                    onComplete(.failure(TransferEngineError.connectionFailed(error.localizedDescription)))
                    return
                }

                bytesTransferred += Int64(chunkData.count)
                let fraction = (totalBytes > 0) ? Double(bytesTransferred) / Double(totalBytes) : 1.0
                onProgress(fraction, bytesTransferred, totalBytes)

                sendNextChunk(itemIndex: itemIndex, offset: offset + UInt64(chunkData.count))
            })
        }

        if startItemIndex < fileHandles.count {
            try? fileHandles[startItemIndex].seek(toOffset: startOffset)
        }
        sendNextChunk(itemIndex: startItemIndex, offset: startOffset)
    }

    public func handleInboundConnection(
        connection: NWConnection,
        trustStore: PinnedTrustStore,
        destinationFolder: URL,
        onProgress: @escaping (Double, TransferRecord) -> Void,
        onComplete: @escaping (Result<TransferRecord, Error>) -> Void
    ) {
        let connectionId = "conn_\(UUID().uuidString.prefix(8).lowercased())"
        NearsideLogger.shared.info(
            "connection",
            "handleInboundConnection",
            "Inbound TCP connection accepted",
            state: "connecting",
            correlationId: connectionId
        )

        connection.stateUpdateHandler = { state in
            switch state {
            case .failed(let error):
                NearsideLogger.shared.error(NearsideError(code: .connectionClosed, operation: "handleInboundConnection", message: "Inbound connection failed: \(error.localizedDescription)", underlyingError: error, correlationId: connectionId), state: "failed")
                connection.cancel()
            default:
                break
            }
        }
        connection.start(queue: self.queue)

        connection.receive(minimumIncompleteLength: 9, maximumLength: 9) { [weak self] headerData, _, _, error in
            guard let self = self else { return }
            if let error = error {
                let err = NearsideError(code: .connectionClosed, operation: "readHeader", message: error.localizedDescription, underlyingError: error, correlationId: connectionId)
                NearsideLogger.shared.error(err, state: "failed")
                onComplete(.failure(err))
                return
            }
            guard let data = headerData, data.count == 9 else {
                let err = NearsideError(code: .protocolMagicMismatch, operation: "readHeader", message: "Invalid manifest header length", correlationId: connectionId)
                NearsideLogger.shared.error(err, state: "failed")
                onComplete(.failure(err))
                return
            }

            let frameType = data[4]
            let len = Int(data.subdata(in: 5..<9).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian)

            if frameType == FrameType.pairRequest.rawValue {
                guard (1...16384).contains(len), data.prefix(4).withUnsafeBytes({ $0.loadUnaligned(as: UInt32.self) }).bigEndian == TransferChunk.magic else {
                    connection.cancel()
                    onComplete(.failure(PairingError.malformedPayload.toNearsideError(correlationId: connectionId)))
                    return
                }
                connection.receive(minimumIncompleteLength: len, maximumLength: len) { payload, _, _, error in
                    guard error == nil, let payload = payload, payload.count == len,
                          let request = try? JSONDecoder().decode(PairRequestFrame.self, from: payload) else {
                        connection.cancel()
                        onComplete(.failure(PairingError.malformedPayload.toNearsideError(correlationId: connectionId)))
                        return
                    }
                    self.handleQRPairRequest(connection: connection, request: request, trustStore: trustStore, onComplete: onComplete)
                }
                return
            }

            connection.receive(minimumIncompleteLength: len, maximumLength: len) { payloadData, _, _, manError in
                if let manError = manError {
                    let err = NearsideError(code: .connectionClosed, operation: "readManifest", message: manError.localizedDescription, underlyingError: manError, correlationId: connectionId)
                    NearsideLogger.shared.error(err, state: "failed")
                    onComplete(.failure(err))
                    return
                }
                guard let payload = payloadData,
                      let manifest = try? JSONDecoder().decode(TransferManifest.self, from: payload) else {
                    let err = NearsideError(code: .protocolDecodeFailed, operation: "decodeManifest", message: "Invalid manifest JSON", correlationId: connectionId)
                    NearsideLogger.shared.error(err, state: "failed")
                    onComplete(.failure(err))
                    return
                }

                NearsideLogger.shared.info(
                    "transfer",
                    "handleInboundConnection",
                    "Received transfer manifest for \(manifest.itemCount) item(s)",
                    state: "negotiating",
                    correlationId: manifest.transferId,
                    metadata: [
                        "totalBytes": "\(manifest.totalBytes)",
                        "sender": NearsideRedactor.sanitizeIdentity(manifest.senderId)
                    ]
                )

                // Strict path traversal defense
                for item in manifest.items {
                    let cleanName = (item.name as NSString).lastPathComponent
                    guard !cleanName.isEmpty,
                          cleanName != ".",
                          cleanName != "..",
                          cleanName == item.name,
                          !item.name.contains("/"),
                          !item.name.contains("\\") else {
                        let err = NearsideError(
                            code: .protocolPathTraversalRejected,
                            operation: "validateManifest",
                            message: "Potential path traversal in item name: \(cleanName)",
                            correlationId: manifest.transferId
                        )
                        NearsideLogger.shared.error(err, state: "rejected")
                        self.sendError(connection: connection, code: 400, reason: "INVALID_FILENAME", detail: "Potential path traversal in item name")
                        onComplete(.failure(err))
                        return
                    }
                }

                guard trustStore.canTransfer(identity: manifest.senderId) else {
                    let blocked = trustStore.isBlocked(identity: manifest.senderId)
                    let error = NearsideError(code: blocked ? .trustPeerBlocked : .trustUntrustedPeer,
                        operation: "verifyTrust", message: "Sender is not permitted", correlationId: manifest.transferId)
                    NearsideLogger.shared.error(error, state: "rejected")
                    self.sendError(connection: connection, code: 403,
                        reason: blocked ? "DEVICE_BLOCKED" : "DEVICE_NOT_PAIRED", detail: "Sender is not permitted")
                    onComplete(.failure(error))
                    return
                }

                var totalResumedBytes: Int64 = 0
                var initialHandles: [Int: FileHandle] = [:]
                var initialHashers: [Int: SHA256] = [:]

                for item in manifest.items {
                    let destURL = destinationFolder.appendingPathComponent(item.name)
                    var itemHasher = SHA256()

                    if FileManager.default.fileExists(atPath: destURL.path),
                       let attrs = try? FileManager.default.attributesOfItem(atPath: destURL.path),
                       let fileSize = (attrs[.size] as? NSNumber)?.int64Value,
                       fileSize > 0 && fileSize <= item.size {

                        if let readHandle = try? FileHandle(forReadingFrom: destURL) {
                            var bytesHashed: Int64 = 0
                            while bytesHashed < fileSize {
                                let chunk = readHandle.readData(ofLength: TransferChunk.maxChunkSize)
                                if chunk.isEmpty { break }
                                itemHasher.update(data: chunk)
                                bytesHashed += Int64(chunk.count)
                            }
                            try? readHandle.close()
                        }

                        if fileSize == item.size {
                            let calculated = itemHasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
                            if calculated == item.sha256 {
                                totalResumedBytes += fileSize
                                initialHashers[item.index] = itemHasher
                                continue
                            }
                        }

                        if let writeHandle = try? FileHandle(forUpdating: destURL) {
                            try? writeHandle.seek(toOffset: UInt64(fileSize))
                            initialHandles[item.index] = writeHandle
                            initialHashers[item.index] = itemHasher
                            totalResumedBytes += fileSize
                            continue
                        }
                    }

                    FileManager.default.createFile(atPath: destURL.path, contents: nil)
                    if let handle = try? FileHandle(forWritingTo: destURL) {
                        initialHandles[item.index] = handle
                        initialHashers[item.index] = SHA256()
                    }
                }

                let ack = TransferAck(
                    transferId: manifest.transferId,
                    status: "ACCEPTED",
                    acceptedItems: manifest.items.map { $0.index },
                    bytesReceived: totalResumedBytes,
                    readyForStream: true
                )

                self.sendAck(connection: connection, ack: ack) {
                    self.receiveInboundChunks(
                        connection: connection,
                        manifest: manifest,
                        destinationFolder: destinationFolder,
                        initialHandles: initialHandles,
                        initialHashers: initialHashers,
                        initialBytesReceived: totalResumedBytes,
                        onProgress: onProgress,
                        onComplete: onComplete
                    )
                }
            }
        }
    }

    private func sendAck(connection: NWConnection, ack: TransferAck, completion: @escaping () -> Void) {
        guard let data = try? JSONEncoder().encode(ack) else { return }
        var packet = Data()
        var magicBE = TransferChunk.magic.bigEndian
        packet.append(Data(bytes: &magicBE, count: 4))
        var type = FrameType.ack.rawValue
        packet.append(Data(bytes: &type, count: 1))
        var lenBE = UInt32(data.count).bigEndian
        packet.append(Data(bytes: &lenBE, count: 4))
        packet.append(data)

        connection.send(content: packet, completion: .contentProcessed { _ in
            completion()
        })
    }

    private func sendError(connection: NWConnection, code: Int, reason: String, detail: String) {
        let err = ErrorFrame(code: code, reason: reason, detail: detail)
        guard let data = try? JSONEncoder().encode(err) else { return }
        var packet = Data()
        var magicBE = TransferChunk.magic.bigEndian
        packet.append(Data(bytes: &magicBE, count: 4))
        var type = FrameType.error.rawValue
        packet.append(Data(bytes: &type, count: 1))
        var lenBE = UInt32(data.count).bigEndian
        packet.append(Data(bytes: &lenBE, count: 4))
        packet.append(data)

        connection.send(content: packet, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func receiveInboundChunks(
        connection: NWConnection,
        manifest: TransferManifest,
        destinationFolder: URL,
        initialHandles: [Int: FileHandle],
        initialHashers: [Int: SHA256],
        initialBytesReceived: Int64,
        onProgress: @escaping (Double, TransferRecord) -> Void,
        onComplete: @escaping (Result<TransferRecord, Error>) -> Void
    ) {
        var currentRecord = TransferRecord(
            id: manifest.transferId,
            deviceName: "Nearby Peer",
            devicePlatform: .android,
            direction: .incoming,
            filename: manifest.items.first?.name ?? "Incoming File",
            fileCount: manifest.itemCount,
            totalSizeBytes: manifest.totalBytes,
            progress: (manifest.totalBytes > 0) ? Double(initialBytesReceived) / Double(manifest.totalBytes) : 0.0,
            status: .transferring,
            timestamp: Date()
        )

        let itemHandles = initialHandles
        var itemHashers = initialHashers
        var bytesReceived: Int64 = initialBytesReceived

        func closeHandles() {
            for (_, h) in itemHandles { try? h.close() }
        }

        func finalizeRecord() {
            currentRecord.progress = 1.0
            currentRecord.status = .completed

            if let firstItem = manifest.items.first,
               (firstItem.mimeType == "text/plain" || firstItem.mimeType == "text/uri-list") {
                let destURL = destinationFolder.appendingPathComponent(firstItem.name)
                if let content = try? String(contentsOf: destURL, encoding: .utf8) {
                    currentRecord.payloadType = (firstItem.mimeType == "text/uri-list") ? .url : .text
                    currentRecord.payloadText = content

                    #if os(macOS)
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(content, forType: .string)
                    #elseif os(iOS)
                    UIPasteboard.general.string = content
                    #endif
                }
            }
        }

        if initialBytesReceived == manifest.totalBytes && manifest.totalBytes > 0 {
            closeHandles()
            finalizeRecord()
            onComplete(.success(currentRecord))
            return
        }

        func receiveNext() {
            connection.receive(minimumIncompleteLength: 9, maximumLength: 9) { headerData, _, _, error in
                if let error = error {
                    closeHandles()
                    onComplete(.failure(TransferEngineError.connectionFailed(error.localizedDescription)))
                    return
                }
                guard let h = headerData, h.count == 9 else {
                    closeHandles()
                    onComplete(.failure(TransferEngineError.connectionFailed("Short chunk header")))
                    return
                }

                let frameType = h[4]
                if frameType == FrameType.complete.rawValue {
                    closeHandles()
                    for item in manifest.items {
                        if let hasher = itemHashers[item.index] {
                            let calculated = hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
                            if calculated != item.sha256 {
                                let err = NearsideError(
                                    code: .verifyFileChecksumMismatch,
                                    operation: "receiveInboundChunks",
                                    message: "File checksum mismatch for \(item.name)",
                                    correlationId: manifest.transferId
                                )
                                NearsideLogger.shared.error(err, state: "failed")
                                onComplete(.failure(err))
                                return
                            }
                        }
                    }
                    finalizeRecord()
                    NearsideLogger.shared.info(
                        "transfer",
                        "receiveInboundChunks",
                        "Inbound transfer completed and verified successfully",
                        state: "completed",
                        correlationId: manifest.transferId,
                        metadata: ["totalBytes": "\(manifest.totalBytes)"]
                    )
                    onComplete(.success(currentRecord))
                    return
                }

                guard frameType == FrameType.chunk.rawValue else {
                    closeHandles()
                    let err = NearsideError(code: .protocolInvalidFrameType, operation: "receiveInboundChunks", message: "Unexpected frame type \(frameType)", correlationId: manifest.transferId)
                    NearsideLogger.shared.error(err, state: "failed")
                    onComplete(.failure(err))
                    return
                }

                let payloadLen = Int(h.subdata(in: 5..<9).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian)
                let remainingExpected = 12 + payloadLen + 32

                connection.receive(minimumIncompleteLength: remainingExpected, maximumLength: remainingExpected) { restData, _, _, restErr in
                    if let restErr = restErr {
                        closeHandles()
                        let err = NearsideError(code: .connectionClosed, operation: "receiveChunk", message: restErr.localizedDescription, underlyingError: restErr, correlationId: manifest.transferId)
                        NearsideLogger.shared.error(err, state: "failed")
                        onComplete(.failure(err))
                        return
                    }
                    guard let r = restData, r.count == remainingExpected else {
                        closeHandles()
                        let err = NearsideError(code: .connectionClosed, operation: "receiveChunk", message: "Incomplete chunk data", correlationId: manifest.transferId)
                        NearsideLogger.shared.error(err, state: "failed")
                        onComplete(.failure(err))
                        return
                    }

                    let itemIndex = Int(r.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian)
                    let offset = r.subdata(in: 4..<12).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.bigEndian
                    let chunkPayload = r.subdata(in: 12..<(12 + payloadLen))
                    let presentedHash = r.subdata(in: (12 + payloadLen)..<remainingExpected)

                    let computedHash = Data(SHA256.hash(data: chunkPayload))
                    guard computedHash == presentedHash else {
                        closeHandles()
                        let err = NearsideError(
                            code: .verifyChunkMismatch,
                            operation: "receiveInboundChunks",
                            message: "Chunk hash mismatch at offset \(offset)",
                            correlationId: manifest.transferId
                        )
                        NearsideLogger.shared.error(err, state: "failed")
                        onComplete(.failure(err))
                        return
                    }

                    if let handle = itemHandles[itemIndex] {
                        try? handle.seek(toOffset: offset)
                        handle.write(chunkPayload)
                        itemHashers[itemIndex]?.update(data: chunkPayload)
                    }

                    bytesReceived += Int64(chunkPayload.count)
                    let progress = (manifest.totalBytes > 0) ? Double(bytesReceived) / Double(manifest.totalBytes) : 1.0
                    currentRecord.progress = progress
                    onProgress(progress, currentRecord)

                    receiveNext()
                }
            }
        }

        receiveNext()
    }
}


extension TransferEngine {
    private func sendPairFrame<T: Encodable>(_ value: T, type: FrameType, connection: NWConnection,
        completion: @escaping (Error?) -> Void) {
        do {
            let payload = try JSONEncoder().encode(value)
            guard (1...16384).contains(payload.count) else { throw PairingError.malformedPayload }
            var data = Data(); var magic = TransferChunk.magic.bigEndian
            data.append(Data(bytes: &magic, count: 4)); data.append(type.rawValue)
            var length = UInt32(payload.count).bigEndian; data.append(Data(bytes: &length, count: 4)); data.append(payload)
            connection.send(content: data, completion: .contentProcessed(completion))
        } catch { completion(error) }
    }

    private func receivePairFrame<T: Decodable>(_ type: T.Type, frameType: FrameType, connection: NWConnection,
        completion: @escaping (Result<T, Error>) -> Void) {
        connection.receive(minimumIncompleteLength: 9, maximumLength: 9) { data, _, _, error in
            if let error = error { completion(.failure(error)); return }
            guard let data = data, data.count == 9,
                  data.prefix(4).withUnsafeBytes({ $0.loadUnaligned(as: UInt32.self) }).bigEndian == TransferChunk.magic,
                  data[4] == frameType.rawValue else { completion(.failure(PairingError.malformedPayload)); return }
            let length = Int(data.suffix(4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian)
            guard (1...16384).contains(length) else { completion(.failure(PairingError.malformedPayload)); return }
            connection.receive(minimumIncompleteLength: length, maximumLength: length) { payload, _, _, error in
                if let error = error { completion(.failure(error)); return }
                guard let payload = payload, payload.count == length else { completion(.failure(PairingError.malformedPayload)); return }
                do { completion(.success(try JSONDecoder().decode(T.self, from: payload))) }
                catch { completion(.failure(PairingError.malformedPayload)) }
            }
        }
    }

    private func handleQRPairRequest(connection: NWConnection, request: PairRequestFrame, trustStore: PinnedTrustStore,
        onComplete: @escaping (Result<TransferRecord, Error>) -> Void) {
        func fail(_ error: Error) {
            let diagnostic = (error as? PairingError)?.toNearsideError(correlationId: request.qrSessionId) ?? error
            if let diagnostic = diagnostic as? NearsideError { NearsideLogger.shared.error(diagnostic, state: "failed") }
            connection.cancel(); onComplete(.failure(diagnostic))
        }
        do {
            guard let sessionId = request.qrSessionId, let clientNonceString = request.qrNonceBase64,
                  let clientNonce = Data(base64Encoded: clientNonceString), clientNonce.count == 32,
                  request.qrConfirmationBase64 == nil else { throw PairingError.malformedPayload }
            let payload = try QRPairingSessions.shared.requireActive(sessionId)
            let identity = DeviceIdentity.loadOrCreateDefault()
            guard payload.hostIdentity == identity.publicIdentity,
                  let spki = Data(base64Encoded: request.clientSpkiBase64),
                  DeviceIdentity.computeIdentity(fromSpki: spki) == request.clientId,
                  let key = try? P256.Signing.PublicKey(derRepresentation: spki) else { throw PairingError.verificationFailed }
            if case .failure(let error) = trustStore.validatePeer(presentedSpki: spki) {
                switch error { case .untrustedPeer: break; default: throw error }
            }
            let session = QRPairingSession(role: .host, localIdentity: identity, payload: payload)
            let transcript = session.buildTranscript(remoteNonce: clientNonce, clientIdentity: request.clientId, serverIdentity: identity.publicIdentity)
            let keys = try session.deriveConfirmationKeys(transcript: transcript)
            #if os(macOS)
            let name = Host.current().localizedName ?? "Mac"
            #else
            let name = UIDevice.current.name
            #endif
            let challenge = PairResponseFrame(status: "CHALLENGE", serverId: identity.publicIdentity, serverName: name,
                serverPlatform: "macos", serverSpkiBase64: identity.spkiDer.base64EncodedString(), qrSessionId: sessionId,
                qrNonceBase64: session.localNonce.base64EncodedString(),
                qrConfirmationBase64: session.generateConfirmation(keys: keys, transcript: transcript).base64EncodedString())
            sendPairFrame(challenge, type: .pairResponse, connection: connection) { error in
                if let error = error { fail(error); return }
                self.receivePairFrame(PairRequestFrame.self, frameType: .pairRequest, connection: connection) { result in
                    do {
                        let proof = try result.get()
                        guard proof.clientId == request.clientId, proof.clientSpkiBase64 == request.clientSpkiBase64,
                              proof.clientName == request.clientName, proof.clientPlatform == request.clientPlatform,
                              proof.timestamp == request.timestamp, proof.confirmationCode == request.confirmationCode,
                              proof.qrSessionId == sessionId, proof.qrNonceBase64 == clientNonceString,
                              let encoded = proof.qrConfirmationBase64, let mac = Data(base64Encoded: encoded) else { throw PairingError.malformedPayload }
                        guard !payload.isExpired, session.verifyPeerConfirmation(peerMac: mac, expectedKey: keys.clientKey, transcript: transcript) else { throw PairingError.verificationFailed }
                        guard QRPairingSessions.shared.consume(sessionId) else { throw PairingError.sessionExpired }
                        trustStore.enroll(identity: request.clientId, name: request.clientName, platform: request.clientPlatform, publicKey: key)
                        let accepted = PairResponseFrame(status: "ACCEPTED", serverId: challenge.serverId, serverName: challenge.serverName,
                            serverPlatform: challenge.serverPlatform, serverSpkiBase64: challenge.serverSpkiBase64,
                            qrSessionId: sessionId, qrNonceBase64: challenge.qrNonceBase64,
                            qrConfirmationBase64: session.generateConfirmation(keys: keys, transcript: transcript + Data("nearside-qr-accepted".utf8)).base64EncodedString())
                        self.sendPairFrame(accepted, type: .pairResponse, connection: connection) { error in
                            if let error = error { fail(error); return }
                            connection.cancel()
                            NearsideLogger.shared.info("pairing", "verifyQR", "Mutual QR pairing completed", state: "completed", correlationId: sessionId)
                            onComplete(.success(TransferRecord(id: "pair_\(sessionId)", deviceName: request.clientName, devicePlatform: .android,
                                direction: .incoming, filename: "Pairing Handshake", fileCount: 0, totalSizeBytes: 0,
                                progress: 1, status: .completed, timestamp: Date())))
                        }
                    } catch { fail(error) }
                }
            }
        } catch { fail(error) }
    }

    private func startQRPairClient(connection: NWConnection, identity: DeviceIdentity, name: String, payload: QRPairingPayload,
        trustStore: PinnedTrustStore, host: String, port: UInt16, finish: @escaping (Result<PairResponseFrame, Error>) -> Void) {
        let session = QRPairingSession(role: .client, localIdentity: identity, payload: payload)
        let request = PairRequestFrame(clientId: identity.publicIdentity, clientName: name, clientPlatform: "macos",
            clientSpkiBase64: identity.spkiDer.base64EncodedString(), confirmationCode: "", qrSessionId: payload.sessionId,
            qrNonceBase64: session.localNonce.base64EncodedString())
        sendPairFrame(request, type: .pairRequest, connection: connection) { error in
            if let error = error { finish(.failure(error)); return }
            self.receivePairFrame(PairResponseFrame.self, frameType: .pairResponse, connection: connection) { result in
                do {
                    let challenge = try result.get()
                    guard challenge.status == "CHALLENGE", challenge.serverId == payload.hostIdentity,
                          challenge.qrSessionId == payload.sessionId,
                          let spki = Data(base64Encoded: challenge.serverSpkiBase64), DeviceIdentity.computeIdentity(fromSpki: spki) == payload.hostIdentity,
                          let key = try? P256.Signing.PublicKey(derRepresentation: spki),
                          let nonceString = challenge.qrNonceBase64, let nonce = Data(base64Encoded: nonceString), nonce.count == 32,
                          let encoded = challenge.qrConfirmationBase64, let mac = Data(base64Encoded: encoded) else { throw PairingError.verificationFailed }
                    if case .failure(let error) = trustStore.validatePeer(presentedSpki: spki) {
                        switch error { case .untrustedPeer: break; default: throw error }
                    }
                    let transcript = session.buildTranscript(remoteNonce: nonce, clientIdentity: identity.publicIdentity, serverIdentity: payload.hostIdentity)
                    let keys = try session.deriveConfirmationKeys(transcript: transcript)
                    guard session.verifyPeerConfirmation(peerMac: mac, expectedKey: keys.serverKey, transcript: transcript) else { throw PairingError.verificationFailed }
                    let proof = PairRequestFrame(clientId: request.clientId, clientName: request.clientName, clientPlatform: request.clientPlatform,
                        clientSpkiBase64: request.clientSpkiBase64, confirmationCode: "", timestamp: request.timestamp,
                        qrSessionId: payload.sessionId, qrNonceBase64: request.qrNonceBase64,
                        qrConfirmationBase64: session.generateConfirmation(keys: keys, transcript: transcript).base64EncodedString())
                    self.sendPairFrame(proof, type: .pairRequest, connection: connection) { error in
                        if let error = error { finish(.failure(error)); return }
                        self.receivePairFrame(PairResponseFrame.self, frameType: .pairResponse, connection: connection) { result in
                            do {
                                let response = try result.get()
                                guard !payload.isExpired, response.status == "ACCEPTED", response.serverId == challenge.serverId,
                                      response.serverSpkiBase64 == challenge.serverSpkiBase64, response.qrSessionId == payload.sessionId,
                                      response.qrNonceBase64 == nonceString, let finalEncoded = response.qrConfirmationBase64,
                                      let finalMac = Data(base64Encoded: finalEncoded), session.verifyPeerConfirmation(peerMac: finalMac,
                                        expectedKey: keys.serverKey, transcript: transcript + Data("nearside-qr-accepted".utf8)) else { throw PairingError.verificationFailed }
                                trustStore.enroll(identity: response.serverId, name: response.serverName, platform: response.serverPlatform, publicKey: key)
                                trustStore.updatePeerEndpoint(identity: response.serverId, ip: host, port: port)
                                finish(.success(response))
                            } catch { finish(.failure((error as? PairingError)?.toNearsideError(correlationId: payload.sessionId) ?? error)) }
                        }
                    }
                } catch { finish(.failure((error as? PairingError)?.toNearsideError(correlationId: payload.sessionId) ?? error)) }
            }
        }
    }
}

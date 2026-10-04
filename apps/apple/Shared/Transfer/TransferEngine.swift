import Foundation
import Network
import CryptoKit

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
}

public struct RetryPolicy: Sendable {
    public let maxAttempts: Int
    public let initialDelay: TimeInterval
    public let multiplier: Double

    public static let `default` = RetryPolicy(maxAttempts: 3, initialDelay: 0.5, multiplier: 2.0)

    public init(maxAttempts: Int = 3, initialDelay: TimeInterval = 0.5, multiplier: Double = 2.0) {
        self.maxAttempts = maxAttempts
        self.initialDelay = initialDelay
        self.multiplier = multiplier
    }

    public func delay(forAttempt attempt: Int) -> TimeInterval {
        guard attempt > 0 else { return 0 }
        return initialDelay * pow(multiplier, Double(attempt - 1))
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

            let shaHex = hasher.finalize().compactMap { String(format: "%02x", $0) }.joined()
            let item = TransferItemManifest(
                index: index,
                name: fileURL.lastPathComponent,
                mimeType: "application/octet-stream",
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

    public func sendFiles(
        files: [URL],
        to device: NearsideDevice,
        senderId: String,
        retryPolicy: RetryPolicy = .default,
        onProgress: @escaping (Double, Int64, Int64) -> Void,
        completion: @escaping (Result<TransferRecord, Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self = self else { return }

            guard let hostStr = device.ipAddress, !hostStr.isEmpty else {
                completion(.failure(TransferEngineError.connectionFailed("No IP address for peer")))
                return
            }

            let portNum = device.port ?? 41433
            let host = NWEndpoint.Host(hostStr)
            let port = NWEndpoint.Port(rawValue: portNum) ?? NWEndpoint.Port(integerLiteral: 41433)

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
                timestamp: Date()
            )

            func executeAttempt(attempt: Int) {
                var handles: [FileHandle] = []
                for fileURL in files {
                    guard let h = try? FileHandle(forReadingFrom: fileURL) else {
                        for opened in handles { try? opened.close() }
                        completion(.failure(TransferEngineError.fileAccessError("Cannot open file: \(fileURL.path)")))
                        return
                    }
                    handles.append(h)
                }

                let connection = NWConnection(host: host, port: port, using: .tcp)
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

                    if attempt < retryPolicy.maxAttempts {
                        let delay = retryPolicy.delay(forAttempt: attempt)
                        self.queue.asyncAfter(deadline: .now() + delay) {
                            executeAttempt(attempt: attempt + 1)
                        }
                    } else {
                        completion(.failure(error))
                    }
                }

                connection.stateUpdateHandler = { [weak self] state in
                    guard let self = self else { return }
                    switch state {
                    case .ready:
                        self.performOutboundStream(
                            connection: connection,
                            manifest: manifest,
                            fileHandles: handles,
                            onProgress: onProgress,
                            onComplete: { result in
                                switch result {
                                case .success:
                                    lock.lock()
                                    hasCompletedOrRetried = true
                                    lock.unlock()
                                    self.activeConnections.removeValue(forKey: transferId)
                                    connection.cancel()
                                    for h in handles { try? h.close() }
                                    var finalRecord = recordTemplate
                                    finalRecord.progress = 1.0
                                    finalRecord.status = .completed
                                    completion(.success(finalRecord))
                                case .failure(let err):
                                    handleAttemptFailure(error: err)
                                }
                            }
                        )
                    case .failed(let err):
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
        connection.receive(minimumIncompleteLength: 9, maximumLength: 9) { headerData, _, isComplete, error in
            if let error = error {
                completion(.failure(TransferEngineError.connectionFailed(error.localizedDescription)))
                return
            }
            guard let data = headerData, data.count == 9 else {
                completion(.failure(TransferEngineError.connectionFailed("Truncated ACK header")))
                return
            }

            let len = Int(data.subdata(in: 5..<9).withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian)
            connection.receive(minimumIncompleteLength: len, maximumLength: len) { payloadData, _, _, ackError in
                if let ackError = ackError {
                    completion(.failure(TransferEngineError.connectionFailed(ackError.localizedDescription)))
                    return
                }
                guard let payload = payloadData,
                      let ack = try? JSONDecoder().decode(TransferAck.self, from: payload) else {
                    completion(.failure(TransferEngineError.connectionFailed("Malformed ACK payload")))
                    return
                }
                completion(.success(ack))
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
        connection.receive(minimumIncompleteLength: 9, maximumLength: 9) { [weak self] headerData, _, _, error in
            guard let self = self else { return }
            if let error = error {
                onComplete(.failure(TransferEngineError.connectionFailed(error.localizedDescription)))
                return
            }
            guard let data = headerData, data.count == 9 else {
                onComplete(.failure(TransferEngineError.connectionFailed("Invalid manifest header")))
                return
            }

            let len = Int(data.subdata(in: 5..<9).withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian)
            connection.receive(minimumIncompleteLength: len, maximumLength: len) { payloadData, _, _, manError in
                if let manError = manError {
                    onComplete(.failure(TransferEngineError.connectionFailed(manError.localizedDescription)))
                    return
                }
                guard let payload = payloadData,
                      let manifest = try? JSONDecoder().decode(TransferManifest.self, from: payload) else {
                    onComplete(.failure(TransferEngineError.manifestRejected("Invalid manifest JSON")))
                    return
                }

                // Strict path traversal defense
                for item in manifest.items {
                    let cleanName = (item.name as NSString).lastPathComponent
                    guard !cleanName.isEmpty,
                          cleanName != ".",
                          cleanName != "..",
                          cleanName == item.name,
                          !item.name.contains("/"),
                          !item.name.contains("\\") else {
                        self.sendError(connection: connection, code: 400, reason: "INVALID_FILENAME", detail: "Potential path traversal in item name")
                        onComplete(.failure(TransferEngineError.manifestRejected("Invalid filename: \(item.name)")))
                        return
                    }
                }

                guard trustStore.isEnrolled(identity: manifest.senderId) else {
                    self.sendError(connection: connection, code: 403, reason: "DEVICE_NOT_PAIRED", detail: "Sender \(manifest.senderId) is not trusted.")
                    onComplete(.failure(TransferEngineError.untrustedPeer(manifest.senderId)))
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

        if initialBytesReceived == manifest.totalBytes && manifest.totalBytes > 0 {
            closeHandles()
            currentRecord.progress = 1.0
            currentRecord.status = .completed
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
                                onComplete(.failure(TransferEngineError.integrityMismatch(item.name)))
                                return
                            }
                        }
                    }
                    currentRecord.progress = 1.0
                    currentRecord.status = .completed
                    onComplete(.success(currentRecord))
                    return
                }

                guard frameType == FrameType.chunk.rawValue else {
                    closeHandles()
                    onComplete(.failure(TransferEngineError.connectionFailed("Unexpected frame type \(frameType)")))
                    return
                }

                let payloadLen = Int(h.subdata(in: 5..<9).withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian)
                let remainingExpected = 12 + payloadLen + 32

                connection.receive(minimumIncompleteLength: remainingExpected, maximumLength: remainingExpected) { restData, _, _, restErr in
                    if let restErr = restErr {
                        closeHandles()
                        onComplete(.failure(TransferEngineError.connectionFailed(restErr.localizedDescription)))
                        return
                    }
                    guard let r = restData, r.count == remainingExpected else {
                        closeHandles()
                        onComplete(.failure(TransferEngineError.connectionFailed("Incomplete chunk data")))
                        return
                    }

                    let itemIndex = Int(r.subdata(in: 0..<4).withUnsafeBytes { $0.load(as: UInt32.self) }.bigEndian)
                    let offset = r.subdata(in: 4..<12).withUnsafeBytes { $0.load(as: UInt64.self) }.bigEndian
                    let chunkPayload = r.subdata(in: 12..<(12 + payloadLen))
                    let presentedHash = r.subdata(in: (12 + payloadLen)..<remainingExpected)

                    let computedHash = Data(SHA256.hash(data: chunkPayload))
                    guard computedHash == presentedHash else {
                        closeHandles()
                        onComplete(.failure(TransferEngineError.integrityMismatch("Chunk integrity failure")))
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

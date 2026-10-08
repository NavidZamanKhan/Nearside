import Foundation
import CryptoKit

public struct TransferItemManifest: Codable, Equatable {
    public let index: Int
    public let name: String
    public let mimeType: String
    public let size: Int64
    public let sha256: String

    public enum CodingKeys: String, CodingKey {
        case index
        case name
        case mimeType = "mime_type"
        case size
        case sha256
    }

    public init(index: Int, name: String, mimeType: String, size: Int64, sha256: String) {
        self.index = index
        self.name = name
        self.mimeType = mimeType
        self.size = size
        self.sha256 = sha256
    }
}

public struct TransferManifest: Codable, Equatable {
    public let transferId: String
    public let senderId: String
    public let totalBytes: Int64
    public let itemCount: Int
    public let items: [TransferItemManifest]

    public enum CodingKeys: String, CodingKey {
        case transferId = "transfer_id"
        case senderId = "sender_id"
        case totalBytes = "total_bytes"
        case itemCount = "item_count"
        case items
    }

    public init(transferId: String, senderId: String, items: [TransferItemManifest]) {
        self.transferId = transferId
        self.senderId = senderId
        self.items = items
        self.itemCount = items.count
        self.totalBytes = items.reduce(0) { $0 + $1.size }
    }

    public static func buildTextManifest(text: String, isURL: Bool = false, senderId: String) -> (manifest: TransferManifest, data: Data) {
        let data = Data(text.utf8)
        let hash = SHA256.hash(data: data).compactMap { String(format: "%02x", $0) }.joined()
        let mimeType = isURL ? "text/uri-list" : "text/plain"
        let name = isURL ? "link.url" : "clipboard.txt"
        let item = TransferItemManifest(
            index: 0,
            name: name,
            mimeType: mimeType,
            size: Int64(data.count),
            sha256: hash
        )
        let manifest = TransferManifest(
            transferId: "tx_\(UUID().uuidString.prefix(12).lowercased())",
            senderId: senderId,
            items: [item]
        )
        return (manifest, data)
    }
}

public struct TransferAck: Codable, Equatable {
    public let transferId: String
    public let status: String
    public let acceptedItems: [Int]
    public let bytesReceived: Int64
    public let readyForStream: Bool

    public enum CodingKeys: String, CodingKey {
        case transferId = "transfer_id"
        case status
        case acceptedItems = "accepted_items"
        case bytesReceived = "bytes_received"
        case readyForStream = "ready_for_stream"
    }

    public init(transferId: String, status: String, acceptedItems: [Int], bytesReceived: Int64, readyForStream: Bool) {
        self.transferId = transferId
        self.status = status
        self.acceptedItems = acceptedItems
        self.bytesReceived = bytesReceived
        self.readyForStream = readyForStream
    }
}

public struct ErrorFrame: Codable, Equatable {
    public let code: Int
    public let reason: String
    public let detail: String

    public init(code: Int, reason: String, detail: String) {
        self.code = code
        self.reason = reason
        self.detail = detail
    }
}

public struct PairRequestFrame: Codable, Equatable {
    public let clientId: String
    public let clientName: String
    public let clientPlatform: String
    public let clientSpkiBase64: String
    public let confirmationCode: String
    public let timestamp: Int64

    public enum CodingKeys: String, CodingKey {
        case clientId = "client_id"
        case clientName = "client_name"
        case clientPlatform = "client_platform"
        case clientSpkiBase64 = "client_spki_base64"
        case confirmationCode = "confirmation_code"
        case timestamp
    }

    public init(clientId: String, clientName: String, clientPlatform: String, clientSpkiBase64: String, confirmationCode: String, timestamp: Int64 = Int64(Date().timeIntervalSince1970)) {
        self.clientId = clientId
        self.clientName = clientName
        self.clientPlatform = clientPlatform
        self.clientSpkiBase64 = clientSpkiBase64
        self.confirmationCode = confirmationCode
        self.timestamp = timestamp
    }
}

public struct PairResponseFrame: Codable, Equatable {
    public let status: String
    public let serverId: String
    public let serverName: String
    public let serverPlatform: String
    public let serverSpkiBase64: String
    public let timestamp: Int64

    public enum CodingKeys: String, CodingKey {
        case status
        case serverId = "server_id"
        case serverName = "server_name"
        case serverPlatform = "server_platform"
        case serverSpkiBase64 = "server_spki_base64"
        case timestamp
    }

    public init(status: String, serverId: String, serverName: String, serverPlatform: String, serverSpkiBase64: String, timestamp: Int64 = Int64(Date().timeIntervalSince1970)) {
        self.status = status
        self.serverId = serverId
        self.serverName = serverName
        self.serverPlatform = serverPlatform
        self.serverSpkiBase64 = serverSpkiBase64
        self.timestamp = timestamp
    }
}

public enum FrameType: UInt8 {
    case manifest = 0x01
    case ack = 0x02
    case chunk = 0x03
    case error = 0x04
    case complete = 0x05
    case pairRequest = 0x10
    case pairResponse = 0x11
}

public struct TransferChunk {
    public static let magic: UInt32 = 0x4E534644 // "NSFD" in ASCII
    public static let maxChunkSize: Int = 64 * 1024 // 64 KiB bounded chunk

    public let itemIndex: UInt32
    public let offset: UInt64
    public let data: Data
    public let sha256Hex: String

    public init(itemIndex: UInt32, offset: UInt64, data: Data) {
        self.itemIndex = itemIndex
        self.offset = offset
        self.data = data
        let hash = SHA256.hash(data: data)
        self.sha256Hex = hash.compactMap { String(format: "%02x", $0) }.joined()
    }

    public func encode() -> Data {
        var packet = Data()
        var magicBE = TransferChunk.magic.bigEndian
        packet.append(Data(bytes: &magicBE, count: 4))

        var type = FrameType.chunk.rawValue
        packet.append(Data(bytes: &type, count: 1))

        var lengthBE = UInt32(data.count).bigEndian
        packet.append(Data(bytes: &lengthBE, count: 4))

        var indexBE = itemIndex.bigEndian
        packet.append(Data(bytes: &indexBE, count: 4))

        var offsetBE = offset.bigEndian
        packet.append(Data(bytes: &offsetBE, count: 8))

        packet.append(data)

        let hash = SHA256.hash(data: data)
        packet.append(contentsOf: hash)

        return packet
    }

    public static func decode(from streamData: Data) -> (chunk: TransferChunk, bytesConsumed: Int)? {
        guard streamData.count >= 21 + 32 else { return nil }

        let magic = streamData.subdata(in: 0..<4).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
        guard magic == TransferChunk.magic else { return nil }

        let frameType = streamData[4]
        guard frameType == FrameType.chunk.rawValue else { return nil }

        let length = Int(streamData.subdata(in: 5..<9).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian)
        guard length <= maxChunkSize else { return nil }

        let totalExpectedLength = 21 + length + 32
        guard streamData.count >= totalExpectedLength else { return nil }

        let itemIndex = streamData.subdata(in: 9..<13).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.bigEndian
        let offset = streamData.subdata(in: 13..<21).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }.bigEndian

        let chunkPayload = streamData.subdata(in: 21..<(21 + length))
        let presentedHash = streamData.subdata(in: (21 + length)..<totalExpectedLength)

        let computedHash = Data(SHA256.hash(data: chunkPayload))
        guard computedHash == presentedHash else { return nil }

        let chunk = TransferChunk(itemIndex: itemIndex, offset: offset, data: chunkPayload)
        return (chunk, totalExpectedLength)
    }
}

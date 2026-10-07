import Foundation

public enum DevicePlatform: String, Codable, CaseIterable {
    case macOS = "macos"
    case android = "android"
    case iOS = "ios"
    case windows = "windows"
    case linux = "linux"

    public var displayName: String {
        switch self {
        case .macOS: return "macOS"
        case .android: return "Android"
        case .iOS: return "iOS"
        case .windows: return "Windows"
        case .linux: return "Linux"
        }
    }

    public var systemSymbolName: String {
        switch self {
        case .macOS: return "laptopcomputer"
        case .android: return "phone.fill"
        case .iOS: return "iphone"
        case .windows: return "desktopcomputer"
        case .linux: return "server.rack"
        }
    }
}

public enum DeviceReachability: String, Codable {
    case online = "ONLINE"
    case busy = "BUSY"
    case unreachable = "UNREACHABLE"
}

public struct NearsideDevice: Identifiable, Codable, Equatable {
    public let id: String
    public var name: String
    public let platform: DevicePlatform
    public var fingerprint: String
    public var ipAddress: String?
    public var port: UInt16?
    public var reachability: DeviceReachability
    public var lastSeen: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        platform: DevicePlatform,
        fingerprint: String,
        ipAddress: String? = nil,
        port: UInt16? = nil,
        reachability: DeviceReachability = .online,
        lastSeen: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.platform = platform
        self.fingerprint = fingerprint
        self.ipAddress = ipAddress
        self.port = port
        self.reachability = reachability
        self.lastSeen = lastSeen
    }

    public var shortFingerprint: String {
        if fingerprint.hasPrefix("ns1_") && fingerprint.count >= 12 {
            let startIndex = fingerprint.index(fingerprint.startIndex, offsetBy: 4)
            let endIndex = fingerprint.index(startIndex, offsetBy: 8)
            return String(fingerprint[startIndex..<endIndex])
        }
        return String(fingerprint.prefix(8))
    }
}

public enum TransferDirection: String, Codable {
    case incoming = "INCOMING"
    case outgoing = "OUTGOING"
}

public enum TransferStatus: String, Codable {
    case transferring = "TRANSFERRING"
    case completed = "COMPLETED"
    case failed = "FAILED"
    case cancelled = "CANCELLED"
}

public enum PayloadType: String, Codable, CaseIterable {
    case file = "file"
    case text = "text"
    case url = "url"
}

public struct TransferRecord: Identifiable, Codable, Equatable {
    public let id: String
    public let deviceName: String
    public let devicePlatform: DevicePlatform
    public let direction: TransferDirection
    public let filename: String
    public let fileCount: Int
    public let totalSizeBytes: Int64
    public var progress: Double
    public var status: TransferStatus
    public let timestamp: Date
    public var payloadType: PayloadType
    public var payloadText: String?

    public init(
        id: String = UUID().uuidString,
        deviceName: String,
        devicePlatform: DevicePlatform,
        direction: TransferDirection,
        filename: String,
        fileCount: Int = 1,
        totalSizeBytes: Int64,
        progress: Double = 1.0,
        status: TransferStatus = .completed,
        timestamp: Date = Date(),
        payloadType: PayloadType = .file,
        payloadText: String? = nil
    ) {
        self.id = id
        self.deviceName = deviceName
        self.devicePlatform = devicePlatform
        self.direction = direction
        self.filename = filename
        self.fileCount = fileCount
        self.totalSizeBytes = totalSizeBytes
        self.progress = progress
        self.status = status
        self.timestamp = timestamp
        self.payloadType = payloadType
        self.payloadText = payloadText
    }

    public var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalSizeBytes)
    }
}

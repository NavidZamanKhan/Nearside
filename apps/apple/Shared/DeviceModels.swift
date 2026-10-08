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
    public var errorCode: String?
    public var errorMessage: String?
    public var correlationId: String?

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
        payloadText: String? = nil,
        errorCode: String? = nil,
        errorMessage: String? = nil,
        correlationId: String? = nil,
        transferSpeedBytesPerSec: Double = 0.0
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
        self.errorCode = errorCode
        self.errorMessage = errorMessage
        self.correlationId = correlationId
        self.transferSpeedBytesPerSec = transferSpeedBytesPerSec
    }

    public var transferSpeedBytesPerSec: Double = 0.0

    public var formattedSize: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: totalSizeBytes)
    }

    public var bytesTransferred: Int64 {
        return Int64(Double(totalSizeBytes) * progress)
    }

    public var formattedBytesTransferred: String {
        return ByteCountFormatter.string(fromByteCount: bytesTransferred, countStyle: .file)
    }

    public var formattedSpeed: String {
        guard transferSpeedBytesPerSec > 1024 else { return "" }
        let mb = transferSpeedBytesPerSec / (1024 * 1024)
        if mb >= 0.1 {
            return String(format: "%.1f MB/s", mb)
        } else {
            let kb = transferSpeedBytesPerSec / 1024
            return String(format: "%.0f KB/s", kb)
        }
    }

    public var estimatedTimeRemaining: String {
        guard transferSpeedBytesPerSec > 1024, totalSizeBytes > bytesTransferred else { return "" }
        let remainingBytes = Double(totalSizeBytes - bytesTransferred)
        let seconds = remainingBytes / transferSpeedBytesPerSec
        if seconds < 2 { return "Few seconds left" }
        if seconds < 60 { return "\(Int(seconds))s left" }
        let mins = Int(seconds) / 60
        return "\(mins)m left"
    }

    public var fileIconName: String {
        if payloadType == .url { return "link.circle.fill" }
        if payloadType == .text { return "doc.on.clipboard.fill" }
        let ext = (filename as NSString).pathExtension.lowercased()
        switch ext {
        case "jpg", "jpeg", "png", "heic", "gif", "webp", "tiff":
            return "photo.fill"
        case "mp4", "mov", "m4v", "mkv", "avi":
            return "video.fill"
        case "mp3", "m4a", "wav", "flac", "aac":
            return "music.note"
        case "zip", "tar", "gz", "bz2", "7z", "dmg", "pkg":
            return "archivebox.fill"
        case "pdf":
            return "doc.richtext.fill"
        default:
            return "doc.fill"
        }
    }
}

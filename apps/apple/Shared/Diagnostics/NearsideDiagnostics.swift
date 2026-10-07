import Foundation

/// Authoritative Nearside Error Code Registry.
/// Format: NS-[SUBSYSTEM]-[NUMBER]
public enum NearsideErrorCode: String, Codable, CaseIterable, Sendable {
    // Discovery
    case discoveryRegistrationFailed = "NS-DISC-001"
    case discoveryBrowserFailed = "NS-DISC-002"
    case discoveryResolveFailed = "NS-DISC-003"

    // Pairing
    case pairingSessionExpired = "NS-PAIR-001"
    case pairingVerificationFailed = "NS-PAIR-002"
    case pairingRateLimitExceeded = "NS-PAIR-003"
    case pairingMalformedPayload = "NS-PAIR-004"

    // Trust
    case trustUntrustedPeer = "NS-TRUST-001"
    case trustPeerBlocked = "NS-TRUST-002"
    case trustKeyMismatch = "NS-TRUST-003"
    case trustStorageFailed = "NS-TRUST-004"

    // Connection
    case connectionTimedOut = "NS-CONN-001"
    case connectionRefused = "NS-CONN-002"
    case connectionClosed = "NS-CONN-003"
    case connectionBindFailed = "NS-CONN-004"

    // Protocol
    case protocolMagicMismatch = "NS-PROTO-001"
    case protocolInvalidFrameType = "NS-PROTO-002"
    case protocolDecodeFailed = "NS-PROTO-003"
    case protocolPathTraversalRejected = "NS-PROTO-004"

    // Transfer
    case transferInterrupted = "NS-TRANSFER-001"
    case transferRejected = "NS-TRANSFER-002"
    case transferRetryExhausted = "NS-TRANSFER-003"
    case transferCancelled = "NS-TRANSFER-004"

    // Verification
    case verifyChunkMismatch = "NS-VERIFY-001"
    case verifyFileChecksumMismatch = "NS-VERIFY-002"

    // Storage
    case storageReadFailed = "NS-STORAGE-001"
    case storageWriteFailed = "NS-STORAGE-002"

    public var subsystem: String {
        let raw = self.rawValue
        if raw.hasPrefix("NS-DISC") { return "discovery" }
        if raw.hasPrefix("NS-PAIR") { return "pairing" }
        if raw.hasPrefix("NS-TRUST") { return "trust" }
        if raw.hasPrefix("NS-CONN") { return "connection" }
        if raw.hasPrefix("NS-PROTO") { return "protocol" }
        if raw.hasPrefix("NS-TRANSFER") { return "transfer" }
        if raw.hasPrefix("NS-VERIFY") { return "verification" }
        if raw.hasPrefix("NS-STORAGE") { return "storage" }
        return "general"
    }
}

/// Central Nearside diagnostic error preserving stable Nearside classification and native cause.
public struct NearsideError: Error, LocalizedError, CustomStringConvertible, Codable, Sendable {
    public let code: NearsideErrorCode
    public let subsystem: String
    public let operation: String
    public let message: String
    public let underlyingErrorDescription: String?
    public let correlationId: String?
    public let retryCount: Int?
    public let timestamp: Date

    public init(
        code: NearsideErrorCode,
        operation: String,
        message: String,
        subsystem: String? = nil,
        underlyingError: Error? = nil,
        correlationId: String? = nil,
        retryCount: Int? = nil,
        timestamp: Date = Date()
    ) {
        self.code = code
        self.subsystem = subsystem ?? code.subsystem
        self.operation = operation
        self.message = message
        if let underlying = underlyingError {
            self.underlyingErrorDescription = String(describing: underlying)
        } else {
            self.underlyingErrorDescription = nil
        }
        self.correlationId = correlationId
        self.retryCount = retryCount
        self.timestamp = timestamp
    }

    public var errorDescription: String? {
        return "[\(code.rawValue)] \(message)"
    }

    public var description: String {
        var parts: [String] = [
            "code=\(code.rawValue)",
            "subsystem=\(subsystem)",
            "operation=\(operation)",
            "message=\"\(message)\""
        ]
        if let cid = correlationId {
            parts.append("correlationId=\(cid)")
        }
        if let rc = retryCount {
            parts.append("retryCount=\(rc)")
        }
        if let under = underlyingErrorDescription {
            parts.append("underlying=\"\(under)\"")
        }
        return "NearsideError(\(parts.joined(separator: ", ")))"
    }
}

/// Log level severity hierarchy.
public enum DiagnosticLogLevel: String, Comparable, Sendable {
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"

    private var priority: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warning: return 2
        case .error: return 3
        }
    }

    public static func < (lhs: DiagnosticLogLevel, rhs: DiagnosticLogLevel) -> Bool {
        return lhs.priority < rhs.priority
    }
}

/// Privacy and security redactor to prevent leaking secrets, credentials, or raw payloads.
public enum NearsideRedactor {
    public static func sanitizePath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        return url.lastPathComponent
    }

    public static func sanitizeIdentity(_ identity: String) -> String {
        if identity.hasPrefix("ns1_") && identity.count > 12 {
            let prefix = identity.prefix(8)
            let suffix = identity.suffix(4)
            return "\(prefix)...\(suffix)"
        }
        return identity
    }

    public static func redactSecret(_ value: String) -> String {
        return "[REDACTED:\(value.count) chars]"
    }
}

/// Central structured diagnostic logger for Nearside.
public final class NearsideLogger: @unchecked Sendable {
    public static let shared = NearsideLogger()

    public var minimumLevel: DiagnosticLogLevel = .info
    private let lock = NSLock()
    public var logHandler: ((String) -> Void)?

    private init() {}

    public func log(
        level: DiagnosticLogLevel,
        subsystem: String,
        operation: String,
        message: String,
        state: String? = nil,
        correlationId: String? = nil,
        errorCode: NearsideErrorCode? = nil,
        retryCount: Int? = nil,
        underlyingError: Error? = nil,
        metadata: [String: String] = [:]
    ) {
        guard level >= minimumLevel else { return }

        var fields: [String] = [
            "level=\(level.rawValue)",
            "subsystem=\(subsystem)",
            "operation=\(operation)"
        ]

        if let state = state {
            fields.append("state=\(state)")
        }
        if let cid = correlationId {
            fields.append("correlationId=\(cid)")
        }
        if let code = errorCode {
            fields.append("errorCode=\(code.rawValue)")
        }
        if let rc = retryCount {
            fields.append("retryCount=\(rc)")
        }
        if let err = underlyingError {
            fields.append("underlying=\"\(String(describing: err))\"")
        }
        for (k, v) in metadata.sorted(by: { $0.key < $1.key }) {
            fields.append("\(k)=\"\(v)\"")
        }
        fields.append("msg=\"\(message)\"")

        let line = fields.joined(separator: " ")

        lock.lock()
        if let handler = logHandler {
            handler(line)
        } else {
            print(line)
        }
        lock.unlock()
    }

    public func debug(_ subsystem: String, _ operation: String, _ message: String, state: String? = nil, correlationId: String? = nil, metadata: [String: String] = [:]) {
        log(level: .debug, subsystem: subsystem, operation: operation, message: message, state: state, correlationId: correlationId, metadata: metadata)
    }

    public func info(_ subsystem: String, _ operation: String, _ message: String, state: String? = nil, correlationId: String? = nil, metadata: [String: String] = [:]) {
        log(level: .info, subsystem: subsystem, operation: operation, message: message, state: state, correlationId: correlationId, metadata: metadata)
    }

    public func warn(_ subsystem: String, _ operation: String, _ message: String, state: String? = nil, correlationId: String? = nil, errorCode: NearsideErrorCode? = nil, retryCount: Int? = nil, underlyingError: Error? = nil, metadata: [String: String] = [:]) {
        log(level: .warning, subsystem: subsystem, operation: operation, message: message, state: state, correlationId: correlationId, errorCode: errorCode, retryCount: retryCount, underlyingError: underlyingError, metadata: metadata)
    }

    public func error(_ error: NearsideError, state: String? = nil, metadata: [String: String] = [:]) {
        var meta = metadata
        if let under = error.underlyingErrorDescription {
            meta["underlyingDesc"] = under
        }
        log(
            level: .error,
            subsystem: error.subsystem,
            operation: error.operation,
            message: error.message,
            state: state,
            correlationId: error.correlationId,
            errorCode: error.code,
            retryCount: error.retryCount,
            metadata: meta
        )
    }
}

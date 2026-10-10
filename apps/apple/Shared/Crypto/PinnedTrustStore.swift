import Foundation
import CryptoKit

public enum TrustError: Error, Equatable {
    case untrustedPeer(identity: String)
    case peerBlocked(identity: String)
    case keyMismatch(identity: String)
    case invalidCertificate(reason: String)
}

public struct TrustedPeerRecord: Codable {
    public let identity: String
    public let name: String
    public let platformRaw: String
    public let spkiBase64: String
    public let enrolledAt: Date
    public var lastKnownIp: String?
    public var lastKnownPort: UInt16?

    public init(
        identity: String,
        name: String,
        platformRaw: String,
        spkiBase64: String,
        enrolledAt: Date,
        lastKnownIp: String? = nil,
        lastKnownPort: UInt16? = nil
    ) {
        self.identity = identity
        self.name = name
        self.platformRaw = platformRaw
        self.spkiBase64 = spkiBase64
        self.enrolledAt = enrolledAt
        self.lastKnownIp = lastKnownIp
        self.lastKnownPort = lastKnownPort
    }
}

public final class PinnedTrustStore {
    private var enrolledKeys: [String: P256.Signing.PublicKey] = [:]
    private var peerMetadata: [String: TrustedPeerRecord] = [:]
    private var blockedIdentities: Set<String> = []
    private let storageURL: URL

    public init(customStorageURL: URL? = nil) {
        if let custom = customStorageURL {
            self.storageURL = custom
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dir = appSupport.appendingPathComponent("com.nearside.app")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.storageURL = dir.appendingPathComponent("trust_store.json")
        }
        loadFromDisk()
    }

    public func enroll(
        identity: String,
        name: String,
        platform: String,
        publicKey: P256.Signing.PublicKey,
        lastKnownIp: String? = nil,
        lastKnownPort: UInt16? = nil
    ) {
        enrolledKeys[identity] = publicKey
        peerMetadata[identity] = TrustedPeerRecord(
            identity: identity,
            name: name,
            platformRaw: platform,
            spkiBase64: publicKey.derRepresentation.base64EncodedString(),
            enrolledAt: Date(),
            lastKnownIp: lastKnownIp,
            lastKnownPort: lastKnownPort
        )
        saveToDisk()
        NearsideLogger.shared.info("trust", "enroll", "Enrolled trusted peer", metadata: [
            "peer": NearsideRedactor.sanitizeIdentity(identity),
            "name": name,
            "platform": platform
        ])
    }

    public func updatePeerEndpoint(identity: String, ip: String?, port: UInt16?) {
        guard var record = peerMetadata[identity] else { return }
        var changed = false
        if let ip = ip, !ip.isEmpty, record.lastKnownIp != ip {
            record.lastKnownIp = ip
            changed = true
        }
        if let port = port, port > 0, record.lastKnownPort != port {
            record.lastKnownPort = port
            changed = true
        }
        if changed {
            peerMetadata[identity] = record
            saveToDisk()
        }
    }

    public func block(identity: String) {
        blockedIdentities.insert(identity)
        saveToDisk()
        NearsideLogger.shared.info("trust", "block", "Blocked peer identity", metadata: ["peer": NearsideRedactor.sanitizeIdentity(identity)])
    }

    public func unpair(identity: String) {
        enrolledKeys.removeValue(forKey: identity)
        peerMetadata.removeValue(forKey: identity)
        blockedIdentities.remove(identity)
        saveToDisk()
        NearsideLogger.shared.info("trust", "unpair", "Unpaired peer", metadata: ["peer": NearsideRedactor.sanitizeIdentity(identity)])
    }

    public func isEnrolled(identity: String) -> Bool {
        return enrolledKeys[identity] != nil
    }

    public func isBlocked(identity: String) -> Bool {
        blockedIdentities.contains(identity)
    }

    public func canTransfer(identity: String) -> Bool {
        isEnrolled(identity: identity) && !isBlocked(identity: identity)
    }

    public func allEnrolledPeers() -> [TrustedPeerRecord] {
        return Array(peerMetadata.values)
    }

    public func validatePeer(presentedSpki: Data) -> Result<String, TrustError> {
        let identity = DeviceIdentity.computeIdentity(fromSpki: presentedSpki)

        if blockedIdentities.contains(identity) {
            NearsideLogger.shared.warn("trust", "validatePeer", "Blocked peer attempted access", metadata: [
                "peer": NearsideRedactor.sanitizeIdentity(identity),
                "code": NearsideErrorCode.trustPeerBlocked.rawValue
            ])
            return .failure(.peerBlocked(identity: identity))
        }

        guard let enrolledKey = enrolledKeys[identity] else {
            NearsideLogger.shared.warn("trust", "validatePeer", "Untrusted peer attempted access", metadata: [
                "peer": NearsideRedactor.sanitizeIdentity(identity),
                "code": NearsideErrorCode.trustUntrustedPeer.rawValue
            ])
            return .failure(.untrustedPeer(identity: identity))
        }

        guard enrolledKey.derRepresentation == presentedSpki else {
            let err = NearsideError(
                code: .trustKeyMismatch,
                operation: "validatePeer",
                message: "Presented SPKI does not match pinned SPKI for peer \(NearsideRedactor.sanitizeIdentity(identity))"
            )
            NearsideLogger.shared.error(err, state: "failed")
            return .failure(.keyMismatch(identity: identity))
        }

        return .success(identity)
    }

    private func saveToDisk() {
        let records = Array(peerMetadata.values)
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: storageURL),
              let records = try? JSONDecoder().decode([TrustedPeerRecord].self, from: data) else {
            return
        }

        for record in records {
            if record.name == "Loopback Sender" || record.identity.contains("test") {
                continue
            }
            if let spkiData = Data(base64Encoded: record.spkiBase64),
               let pubKey = try? P256.Signing.PublicKey(derRepresentation: spkiData) {
                enrolledKeys[record.identity] = pubKey
                peerMetadata[record.identity] = record
            }
        }
    }
}

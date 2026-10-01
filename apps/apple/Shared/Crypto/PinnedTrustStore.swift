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

    public func enroll(identity: String, name: String, platform: String, publicKey: P256.Signing.PublicKey) {
        enrolledKeys[identity] = publicKey
        peerMetadata[identity] = TrustedPeerRecord(
            identity: identity,
            name: name,
            platformRaw: platform,
            spkiBase64: publicKey.derRepresentation.base64EncodedString(),
            enrolledAt: Date()
        )
        saveToDisk()
    }

    public func block(identity: String) {
        blockedIdentities.insert(identity)
        saveToDisk()
    }

    public func unpair(identity: String) {
        enrolledKeys.removeValue(forKey: identity)
        peerMetadata.removeValue(forKey: identity)
        blockedIdentities.remove(identity)
        saveToDisk()
    }

    public func isEnrolled(identity: String) -> Bool {
        return enrolledKeys[identity] != nil
    }

    public func allEnrolledPeers() -> [TrustedPeerRecord] {
        return Array(peerMetadata.values)
    }

    public func validatePeer(presentedSpki: Data) -> Result<String, TrustError> {
        let identity = DeviceIdentity.computeIdentity(fromSpki: presentedSpki)

        if blockedIdentities.contains(identity) {
            return .failure(.peerBlocked(identity: identity))
        }

        guard let enrolledKey = enrolledKeys[identity] else {
            return .failure(.untrustedPeer(identity: identity))
        }

        guard enrolledKey.derRepresentation == presentedSpki else {
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
            if let spkiData = Data(base64Encoded: record.spkiBase64),
               let pubKey = try? P256.Signing.PublicKey(derRepresentation: spkiData) {
                enrolledKeys[record.identity] = pubKey
                peerMetadata[record.identity] = record
            }
        }
    }
}

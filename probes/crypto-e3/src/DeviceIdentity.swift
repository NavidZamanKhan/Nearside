import Foundation
import CryptoKit

public struct DeviceIdentity {
    public let privateKey: P256.Signing.PrivateKey
    public let publicKey: P256.Signing.PublicKey
    public let publicIdentity: String
    public let spkiDer: Data

    public init(privateKey: P256.Signing.PrivateKey = P256.Signing.PrivateKey()) {
        self.privateKey = privateKey
        self.publicKey = privateKey.publicKey
        self.spkiDer = privateKey.publicKey.derRepresentation

        let digest = SHA256.hash(data: self.spkiDer)
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
        self.publicIdentity = "ns1_\(hex)"
    }

    public static func computeIdentity(fromSpki spki: Data) -> String {
        let digest = SHA256.hash(data: spki)
        let hex = digest.compactMap { String(format: "%02x", $0) }.joined()
        return "ns1_\(hex)"
    }

    public func sign(data: Data) throws -> Data {
        let signature = try privateKey.signature(for: data)
        return signature.rawRepresentation
    }

    public static func verify(signature: Data, for data: Data, publicKey: P256.Signing.PublicKey) -> Bool {
        guard let ecdsaSignature = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else {
            return false
        }
        return publicKey.isValidSignature(ecdsaSignature, for: data)
    }
}

public struct PinnedTrustStore {
    private var enrolledKeys: [String: P256.Signing.PublicKey] = [:]
    private var blockedIdentities: Set<String> = []

    public init() {}

    public mutating func enroll(identity: String, publicKey: P256.Signing.PublicKey) {
        enrolledKeys[identity] = publicKey
    }

    public mutating func block(identity: String) {
        blockedIdentities.insert(identity)
    }

    public mutating func unpair(identity: String) {
        enrolledKeys.removeValue(forKey: identity)
        blockedIdentities.remove(identity)
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
}

public enum TrustError: Error, Equatable {
    case untrustedPeer(identity: String)
    case peerBlocked(identity: String)
    case keyMismatch(identity: String)
    case invalidCertificate(reason: String)
}

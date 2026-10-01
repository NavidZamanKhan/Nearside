import Foundation
import CryptoKit

public struct PakeSessionConfig {
    public let sessionId: String
    public let shortCode: String // 8-digit numeric code
    public let serverIdentity: String
    public let clientIdentity: String
    public let createdAt: Double
    public let maxAttempts: Int
    public let expirySeconds: Double

    public init(shortCode: String, serverIdentity: String, clientIdentity: String, maxAttempts: Int = 5, expirySeconds: Double = 120.0) {
        self.sessionId = UUID().uuidString
        self.shortCode = shortCode
        self.serverIdentity = serverIdentity
        self.clientIdentity = clientIdentity
        self.createdAt = Date().timeIntervalSince1970
        self.maxAttempts = maxAttempts
        self.expirySeconds = expirySeconds
    }

    public var isExpired: Bool {
        return (Date().timeIntervalSince1970 - createdAt) > expirySeconds
    }
}

public final class ShortCodePakeParticipant {
    public enum Role: String {
        case server = "SERVER"
        case client = "CLIENT"
    }

    public let role: Role
    public let config: PakeSessionConfig
    public let ephemeralPrivateKey: P256.KeyAgreement.PrivateKey
    public let ephemeralPublicKey: P256.KeyAgreement.PublicKey
    public let localNonce: Data

    private(set) public var failedAttempts: Int = 0
    private(set) public var isLockedOut: Bool = false

    public init(role: Role, config: PakeSessionConfig) {
        self.role = role
        self.config = config
        self.ephemeralPrivateKey = P256.KeyAgreement.PrivateKey()
        self.ephemeralPublicKey = ephemeralPrivateKey.publicKey

        var nonce = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &nonce)
        self.localNonce = Data(nonce)
    }

    public func buildTranscript(remoteEphemeralKey: P256.KeyAgreement.PublicKey, remoteNonce: Data) -> Data {
        var transcript = Data()
        transcript.append(contentsOf: "nearside-pake-v1".utf8)
        transcript.append(contentsOf: config.sessionId.utf8)
        transcript.append(contentsOf: config.serverIdentity.utf8)
        transcript.append(contentsOf: config.clientIdentity.utf8)

        let (serverKey, clientKey) = (role == .server)
            ? (ephemeralPublicKey.rawRepresentation, remoteEphemeralKey.rawRepresentation)
            : (remoteEphemeralKey.rawRepresentation, ephemeralPublicKey.rawRepresentation)
        transcript.append(serverKey)
        transcript.append(clientKey)

        let (serverNonce, clientNonce) = (role == .server)
            ? (localNonce, remoteNonce)
            : (remoteNonce, localNonce)
        transcript.append(serverNonce)
        transcript.append(clientNonce)

        return transcript
    }

    public func computeConfirmationKeys(
        peerEphemeralKey: P256.KeyAgreement.PublicKey,
        peerNonce: Data,
        enteredCode: String
    ) throws -> (clientKey: SymmetricKey, serverKey: SymmetricKey) {
        guard !config.isExpired else {
            throw PakeError.sessionExpired
        }
        guard !isLockedOut else {
            throw PakeError.maxAttemptsExceeded
        }

        // PAKE secret generation blending ECDH with entered code
        let sharedSecret = try ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: peerEphemeralKey)
        let transcript = buildTranscript(remoteEphemeralKey: peerEphemeralKey, remoteNonce: peerNonce)

        // Code blinding salt
        let codeSalt = Data(SHA256.hash(data: "\(enteredCode):\(config.sessionId)".data(using: .utf8)!))

        let clientKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: codeSalt,
            sharedInfo: Data("nearside-pake-client-confirm".utf8) + transcript,
            outputByteCount: 32
        )

        let serverKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: codeSalt,
            sharedInfo: Data("nearside-pake-server-confirm".utf8) + transcript,
            outputByteCount: 32
        )

        return (clientKey, serverKey)
    }

    public func generateConfirmationTag(keys: (clientKey: SymmetricKey, serverKey: SymmetricKey), transcript: Data) -> Data {
        let key = (role == .client) ? keys.clientKey : keys.serverKey
        let mac = HMAC<SHA256>.authenticationCode(for: transcript, using: key)
        return Data(mac)
    }

    public func verifyConfirmationTag(
        peerTag: Data,
        expectedKey: SymmetricKey,
        transcript: Data
    ) -> Result<Void, PakeError> {
        guard !isLockedOut else {
            return .failure(.maxAttemptsExceeded)
        }
        guard !config.isExpired else {
            return .failure(.sessionExpired)
        }

        let expectedTag = HMAC<SHA256>.authenticationCode(for: transcript, using: expectedKey)
        let isValid = constantTimeCompare(Data(expectedTag), peerTag)

        if isValid {
            return .success(())
        } else {
            failedAttempts += 1
            if failedAttempts >= config.maxAttempts {
                isLockedOut = true
            }
            return .failure(.tagMismatch(attemptsRemaining: max(0, config.maxAttempts - failedAttempts)))
        }
    }

    private func constantTimeCompare(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var result: UInt8 = 0
        for i in 0..<a.count {
            result |= a[i] ^ b[i]
        }
        return result == 0
    }
}

public enum PakeError: Error, Equatable {
    case sessionExpired
    case maxAttemptsExceeded
    case tagMismatch(attemptsRemaining: Int)
}

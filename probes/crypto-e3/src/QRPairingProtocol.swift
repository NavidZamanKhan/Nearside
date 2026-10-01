import Foundation
import CryptoKit

public struct QRPairingPayload: Codable {
    public let version: Int
    public let sessionId: String
    public let hostIdentity: String
    public let sharedSecretBase64: String
    public let createdAt: Double
    public let expirySeconds: Double

    public init(hostIdentity: String, expirySeconds: Double = 120.0) {
        self.version = 1
        self.sessionId = UUID().uuidString
        self.hostIdentity = hostIdentity
        var secretBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &secretBytes)
        self.sharedSecretBase64 = Data(secretBytes).base64EncodedString()
        self.createdAt = Date().timeIntervalSince1970
        self.expirySeconds = expirySeconds
    }

    public var isExpired: Bool {
        return (Date().timeIntervalSince1970 - createdAt) > expirySeconds
    }
}

public final class QRPairingSession {
    public let role: Role
    public let localIdentity: DeviceIdentity
    public let payload: QRPairingPayload
    public let localNonce: Data

    public enum Role {
        case host // Displays QR
        case client // Scans QR
    }

    public init(role: Role, localIdentity: DeviceIdentity, payload: QRPairingPayload) {
        self.role = role
        self.localIdentity = localIdentity
        self.payload = payload

        var nonce = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &nonce)
        self.localNonce = Data(nonce)
    }

    public func buildTranscript(remoteNonce: Data, clientIdentity: String, serverIdentity: String) -> Data {
        var transcript = Data()
        transcript.append(contentsOf: "nearside-qr-v1".utf8)
        transcript.append(contentsOf: payload.sessionId.utf8)
        transcript.append(clientIdentity.data(using: .utf8)!)
        transcript.append(serverIdentity.data(using: .utf8)!)
        if role == .client {
            transcript.append(localNonce)
            transcript.append(remoteNonce)
        } else {
            transcript.append(remoteNonce)
            transcript.append(localNonce)
        }
        return transcript
    }

    public func deriveConfirmationKeys(transcript: Data) throws -> (clientKey: SymmetricKey, serverKey: SymmetricKey) {
        guard !payload.isExpired else {
            throw PairingError.sessionExpired
        }
        guard let secretData = Data(base64Encoded: payload.sharedSecretBase64), secretData.count == 32 else {
            throw PairingError.invalidSecret
        }

        let inputKeyMaterial = SymmetricKey(data: secretData)
        let salt = Data(SHA256.hash(data: transcript))

        let clientKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKeyMaterial,
            salt: salt,
            info: Data("nearside-qr-client-confirm".utf8),
            outputByteCount: 32
        )

        let serverKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKeyMaterial,
            salt: salt,
            info: Data("nearside-qr-server-confirm".utf8),
            outputByteCount: 32
        )

        return (clientKey, serverKey)
    }

    public func generateConfirmation(keys: (clientKey: SymmetricKey, serverKey: SymmetricKey), transcript: Data) -> Data {
        let key = (role == .client) ? keys.clientKey : keys.serverKey
        let mac = HMAC<SHA256>.authenticationCode(for: transcript, using: key)
        return Data(mac)
    }

    public func verifyPeerConfirmation(peerMac: Data, expectedKey: SymmetricKey, transcript: Data) -> Bool {
        let expectedMac = HMAC<SHA256>.authenticationCode(for: transcript, using: expectedKey)
        // Constant time comparison
        return constantTimeCompare(Data(expectedMac), peerMac)
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

public enum PairingError: Error, Equatable {
    case sessionExpired
    case invalidSecret
    case pinMismatch
    case confirmationFailed
}

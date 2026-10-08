import Foundation
import CryptoKit

public enum PairingError: Error, Equatable {
    case sessionExpired
    case invalidSecret
    case verificationFailed
    case malformedPayload

    public func toNearsideError(correlationId: String? = nil) -> NearsideError {
        switch self {
        case .sessionExpired:
            return NearsideError(code: .pairingSessionExpired, operation: "verifyQR", message: "QR pairing session expired", correlationId: correlationId)
        case .invalidSecret, .verificationFailed:
            return NearsideError(code: .pairingVerificationFailed, operation: "verifyQR", message: "QR pairing verification failed", correlationId: correlationId)
        case .malformedPayload:
            return NearsideError(code: .pairingMalformedPayload, operation: "parseQR", message: "Malformed QR pairing payload", correlationId: correlationId)
        }
    }
}

public struct QRPairingPayload: Codable {
    public let version: Int
    public let sessionId: String
    public let hostIdentity: String
    public let hostName: String
    public let sharedSecretBase64: String
    public let ip: String?
    public let port: Int?
    public let createdAt: Double
    public let expirySeconds: Double

    public init(hostIdentity: String, hostName: String, ip: String? = nil, port: Int? = 41433, expirySeconds: Double = 180.0) {
        self.version = 1
        self.sessionId = UUID().uuidString
        self.hostIdentity = hostIdentity
        self.hostName = hostName
        self.ip = ip
        self.port = port
        var secretBytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &secretBytes)
        self.sharedSecretBase64 = Data(secretBytes).base64EncodedString()
        self.createdAt = Date().timeIntervalSince1970
        self.expirySeconds = expirySeconds
    }

    public var isExpired: Bool {
        return (Date().timeIntervalSince1970 - createdAt) > expirySeconds
    }

    public func toURI() -> String {
        var components = URLComponents()
        components.scheme = "nearside"
        components.host = "pair"
        var items = [
            URLQueryItem(name: "v", value: String(version)),
            URLQueryItem(name: "sid", value: sessionId),
            URLQueryItem(name: "id", value: hostIdentity),
            URLQueryItem(name: "name", value: hostName),
            URLQueryItem(name: "sec", value: sharedSecretBase64)
        ]
        if let ip = ip, !ip.isEmpty {
            items.append(URLQueryItem(name: "ip", value: ip))
            items.append(URLQueryItem(name: "port", value: String(port ?? 41433)))
        }
        components.queryItems = items
        return components.string ?? "nearside://pair"
    }

    public static func fromURI(_ uriString: String) -> QRPairingPayload? {
        guard let components = URLComponents(string: uriString),
              components.scheme == "nearside",
              components.host == "pair",
              let queryItems = components.queryItems else {
            return nil
        }

        let dict = Dictionary(uniqueKeysWithValues: queryItems.compactMap { item in
            item.value.map { (item.name, $0) }
        })

        guard let sid = dict["sid"],
              let id = dict["id"],
              let sec = dict["sec"] else {
            return nil
        }

        let name = dict["name"] ?? "Nearby Peer"
        let version = Int(dict["v"] ?? "1") ?? 1
        let ip = dict["ip"]
        let port = dict["port"].flatMap { Int($0) } ?? 41433

        return QRPairingPayload(
            version: version,
            sessionId: sid,
            hostIdentity: id,
            hostName: name,
            sharedSecretBase64: sec,
            ip: ip,
            port: port,
            createdAt: Date().timeIntervalSince1970,
            expirySeconds: 180.0
        )
    }

    private init(
        version: Int,
        sessionId: String,
        hostIdentity: String,
        hostName: String,
        sharedSecretBase64: String,
        ip: String?,
        port: Int?,
        createdAt: Double,
        expirySeconds: Double
    ) {
        self.version = version
        self.sessionId = sessionId
        self.hostIdentity = hostIdentity
        self.hostName = hostName
        self.sharedSecretBase64 = sharedSecretBase64
        self.ip = ip
        self.port = port
        self.createdAt = createdAt
        self.expirySeconds = expirySeconds
    }
}

public final class QRPairingSession {
    public let role: Role
    public let localIdentity: DeviceIdentity
    public let payload: QRPairingPayload
    public let localNonce: Data

    public enum Role {
        case host
        case client
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
        let expectedData = Data(expectedMac)

        guard peerMac.count == expectedData.count else { return false }
        var result: UInt8 = 0
        for (b1, b2) in zip(peerMac, expectedData) {
            result |= (b1 ^ b2)
        }
        return result == 0
    }
}

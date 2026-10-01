import Foundation
import CryptoKit
import Security

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

    public static func loadOrCreateDefault() -> DeviceIdentity {
        let tag = "com.nearside.identity.p256".data(using: .utf8)!
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnData as String: true
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let keyData = item as? Data,
           let privKey = try? P256.Signing.PrivateKey(rawRepresentation: keyData) {
            return DeviceIdentity(privateKey: privKey)
        }

        // Generate new persistent identity
        let newKey = P256.Signing.PrivateKey()
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: tag,
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecValueData as String: newKey.rawRepresentation,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]
        SecItemDelete(query as CFDictionary)
        SecItemAdd(addQuery as CFDictionary, nil)

        return DeviceIdentity(privateKey: newKey)
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

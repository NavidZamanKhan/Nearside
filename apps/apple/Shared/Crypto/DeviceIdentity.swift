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

    /// Compatibility for callers initialized synchronously. Identity failures
    /// are fatal rather than silently changing an already enrolled device key.
    public static func loadOrCreateDefault() -> DeviceIdentity {
        do { return try loadOrCreatePersistent() }
        catch {
            let failure = (error as? NearsideError) ?? NearsideError(code: .trustStorageFailed,
                operation: "loadDeviceIdentity", message: "Persistent device identity is unavailable.")
            NearsideLogger.shared.error(failure, state: "failed")
            fatalError("[NS-TRUST-004] Persistent device identity is unavailable; unlock Keychain and restart Nearside.")
        }
    }

    public static func loadOrCreatePersistent() throws -> DeviceIdentity {
        let service = "com.nearside.app.identity"
        let account = "p256"
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true
        ]
        return try loadOrCreatePersistent(readKey: {
            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            if status == errSecSuccess {
                return (status, item as? Data)
            }
            let legacyTag = Data("com.nearside.identity.p256".utf8)
            let legacyQuery: [String: Any] = [
                kSecClass as String: kSecClassKey,
                kSecAttrApplicationTag as String: legacyTag,
                kSecMatchLimit as String: kSecMatchLimitOne,
                kSecReturnData as String: true
            ]
            var legacyItem: CFTypeRef?
            let legacyStatus = SecItemCopyMatching(legacyQuery as CFDictionary, &legacyItem)
            if legacyStatus == errSecSuccess {
                return (legacyStatus, legacyItem as? Data)
            }
            return (status, nil)
        }, addKey: { data in
            let addQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            ]
            return SecItemAdd(addQuery as CFDictionary, nil)
        })
    }

    /// Injectable persistence boundary for regression tests; private key bytes
    /// remain in Keychain in production and are never exported to a container.
    static func loadOrCreatePersistent(readKey: () -> (OSStatus, Data?),
                                       addKey: (Data) -> OSStatus) throws -> DeviceIdentity {
        func decode(_ data: Data?) throws -> DeviceIdentity {
            guard let data, let key = try? P256.Signing.PrivateKey(rawRepresentation: data) else {
                throw NearsideError(code: .trustStorageFailed, operation: "loadDeviceIdentity",
                    message: "The stored device identity is invalid. Existing Keychain data was preserved.")
            }
            return DeviceIdentity(privateKey: key)
        }
        func storageFailure(_ status: OSStatus) -> NearsideError {
            NearsideError(code: .trustStorageFailed, operation: "loadDeviceIdentity",
                message: "Cannot access the persistent device identity. Unlock Keychain and restart Nearside.",
                underlyingError: NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
        }
        let (status, existing) = readKey()
        if status == errSecSuccess { return try decode(existing) }
        // Denied access, locked Keychain and corrupt data must never delete or
        // replace an enrolled key. Only a confirmed missing item allows creation.
        guard status == errSecItemNotFound else { throw storageFailure(status) }
        let candidate = P256.Signing.PrivateKey()
        let addStatus = addKey(candidate.rawRepresentation)
        if addStatus == errSecSuccess { return DeviceIdentity(privateKey: candidate) }
        if addStatus == errSecDuplicateItem {
            // A concurrent host initialization may have created the identity.
            let (rereadStatus, persisted) = readKey()
            guard rereadStatus == errSecSuccess else { throw storageFailure(rereadStatus) }
            return try decode(persisted)
        }
        throw storageFailure(addStatus)
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

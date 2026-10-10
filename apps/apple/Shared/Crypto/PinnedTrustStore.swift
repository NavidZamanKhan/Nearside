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

public final class PinnedTrustStore: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var loadFailed = false
    private struct Snapshot: Codable {
        let records: [TrustedPeerRecord]
        let blocked: Set<String>
    }
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
            self.storageURL = dir.appendingPathComponent("trust_store.json")
            do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
            catch {
                loadFailed = true
                NearsideLogger.shared.error(storageFailure(operation: "createTrustDirectory", cause: error), state: "failed")
            }
        }
        loadFromDisk()
    }

    public func enroll(
        identity: String, name: String, platform: String, publicKey: P256.Signing.PublicKey,
        lastKnownIp: String? = nil, lastKnownPort: UInt16? = nil
    ) {
        do { try enrollVerifiedPeer(identity: identity, name: name, platform: platform, publicKey: publicKey,
            lastKnownIp: lastKnownIp, lastKnownPort: lastKnownPort) }
        catch {
            NearsideLogger.shared.error((error as? NearsideError) ?? storageFailure(operation: "enroll", cause: error), state: "failed")
        }
    }

    /// Pairing uses this transactional API: success requires durable pin storage.
    public func enrollVerifiedPeer(
        identity: String, name: String, platform: String, publicKey: P256.Signing.PublicKey,
        lastKnownIp: String? = nil, lastKnownPort: UInt16? = nil
    ) throws {
        lock.lock(); defer { lock.unlock() }
        guard DeviceIdentity.computeIdentity(fromSpki: publicKey.derRepresentation) == identity else {
            throw NearsideError(code: .trustKeyMismatch, operation: "enrollVerifiedPeer",
                message: "Peer identity does not match its public key.")
        }
        let previousKey = enrolledKeys[identity]
        let previousRecord = peerMetadata[identity]
        enrolledKeys[identity] = publicKey
        peerMetadata[identity] = TrustedPeerRecord(identity: identity, name: name, platformRaw: platform,
            spkiBase64: publicKey.derRepresentation.base64EncodedString(), enrolledAt: Date(),
            lastKnownIp: lastKnownIp, lastKnownPort: lastKnownPort)
        do { try saveToDisk() }
        catch {
            enrolledKeys[identity] = previousKey
            peerMetadata[identity] = previousRecord
            throw error
        }
        NearsideLogger.shared.info("trust", "enroll", "Enrolled trusted peer", metadata: [
            "peer": NearsideRedactor.sanitizeIdentity(identity), "platform": platform
        ])
    }

    public func updatePeerEndpoint(identity: String, ip: String?, port: UInt16?) {
        lock.lock(); defer { lock.unlock() }
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
            let previous = peerMetadata[identity]
            peerMetadata[identity] = record
            do { try saveToDisk() }
            catch {
                peerMetadata[identity] = previous
                NearsideLogger.shared.error((error as? NearsideError) ?? storageFailure(operation: "updatePeerEndpoint", cause: error), state: "failed")
            }
        }
    }

    public func block(identity: String) {
        lock.lock(); defer { lock.unlock() }
        blockedIdentities.insert(identity)
        do { try saveToDisk() }
        catch { NearsideLogger.shared.error((error as? NearsideError) ?? storageFailure(operation: "saveTrustStore", cause: error), state: "failed") }
        NearsideLogger.shared.info("trust", "block", "Blocked peer identity", metadata: ["peer": NearsideRedactor.sanitizeIdentity(identity)])
    }

    public func unpair(identity: String) {
        lock.lock(); defer { lock.unlock() }
        enrolledKeys.removeValue(forKey: identity)
        peerMetadata.removeValue(forKey: identity)
        blockedIdentities.remove(identity)
        do { try saveToDisk() }
        catch { NearsideLogger.shared.error((error as? NearsideError) ?? storageFailure(operation: "saveTrustStore", cause: error), state: "failed") }
        NearsideLogger.shared.info("trust", "unpair", "Unpaired peer", metadata: ["peer": NearsideRedactor.sanitizeIdentity(identity)])
    }

    public func isEnrolled(identity: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return enrolledKeys[identity] != nil
    }

    public func isBlocked(identity: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return blockedIdentities.contains(identity)
    }

    public func canTransfer(identity: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !loadFailed && isEnrolled(identity: identity) && !isBlocked(identity: identity)
    }

    public func allEnrolledPeers() -> [TrustedPeerRecord] {
        lock.lock(); defer { lock.unlock() }
        return Array(peerMetadata.values)
    }

    public func validatePeer(presentedSpki: Data) -> Result<String, TrustError> {
        lock.lock(); defer { lock.unlock() }
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

    private func saveToDisk() throws {
        lock.lock(); defer { lock.unlock() }
        guard !loadFailed else {
            throw NearsideError(code: .trustStorageFailed, operation: "saveTrustStore",
                message: "Trust storage could not be read. Existing data was preserved; restore it before pairing.")
        }
        do {
            let snapshot = Snapshot(records: Array(peerMetadata.values), blocked: blockedIdentities)
            try JSONEncoder().encode(snapshot).write(to: storageURL, options: .atomic)
        } catch { throw storageFailure(operation: "saveTrustStore", cause: error) }
    }

    private func loadFromDisk() {
        lock.lock(); defer { lock.unlock() }
        guard !loadFailed else { return }
        let data: Data
        do { data = try Data(contentsOf: storageURL) }
        catch {
            let native = error as NSError
            if native.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(native.code) { return }
            loadFailed = true
            NearsideLogger.shared.error(storageFailure(operation: "loadTrustStore", cause: error), state: "failed")
            return
        }
        do {
            let records: [TrustedPeerRecord]
            let blocked: Set<String>
            if let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) {
                records = snapshot.records
                blocked = snapshot.blocked
            } else {
                records = try JSONDecoder().decode([TrustedPeerRecord].self, from: data)
                blocked = []
            }
            var keys: [String: P256.Signing.PublicKey] = [:]
            var metadata: [String: TrustedPeerRecord] = [:]
            for record in records {
                guard let spki = Data(base64Encoded: record.spkiBase64),
                      let key = try? P256.Signing.PublicKey(derRepresentation: spki),
                      DeviceIdentity.computeIdentity(fromSpki: spki) == record.identity,
                      keys[record.identity] == nil else {
                    throw NearsideError(code: .trustStorageFailed, operation: "loadTrustStore",
                        message: "Trust storage contains an invalid peer record. Existing data was preserved.")
                }
                keys[record.identity] = key
                metadata[record.identity] = record
            }
            enrolledKeys = keys
            peerMetadata = metadata
            blockedIdentities = blocked
        } catch {
            loadFailed = true
            NearsideLogger.shared.error((error as? NearsideError) ?? storageFailure(operation: "loadTrustStore", cause: error), state: "failed")
        }
    }

    private func storageFailure(operation: String, cause: Error) -> NearsideError {
        let native = cause as NSError
        return NearsideError(code: .trustStorageFailed, operation: operation,
            message: "Trust storage is unavailable. Check local storage access and retry; existing data was preserved.",
            underlyingError: NSError(domain: native.domain, code: native.code))
    }
}

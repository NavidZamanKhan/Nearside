import Foundation
import CryptoKit

@main
struct TrustStorageRegressionTests {
    static func main() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("NearsideTrustTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        NearsideLogger.shared.minimumLevel = .error
        defer { NearsideLogger.shared.minimumLevel = .info; NearsideLogger.shared.logHandler = nil }
        let peer = DeviceIdentity()
        let other = DeviceIdentity()
        let file = root.appendingPathComponent("trust.json")
        let store = PinnedTrustStore(customStorageURL: file)
        try store.enrollVerifiedPeer(identity: peer.publicIdentity, name: "Peer", platform: "android", publicKey: peer.publicKey)
        check(PinnedTrustStore(customStorageURL: file).canTransfer(identity: peer.publicIdentity), "Verified enrollment persists before reporting success")
        rejects(.trustKeyMismatch, "Enrollment rejects a mismatched identity and public key") {
            try store.enrollVerifiedPeer(identity: peer.publicIdentity, name: "Wrong", platform: "android", publicKey: other.publicKey)
        }
        check(store.validatePeer(presentedSpki: peer.spkiDer) == .success(peer.publicIdentity), "Rejected enrollment preserves the original pin")

        let backup = root.appendingPathComponent("saved.json")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        let savedBytes = try Data(contentsOf: backup)
        var lines: [String] = []
        NearsideLogger.shared.logHandler = { lines.append($0) }
        rejects(.trustStorageFailed, "Storage write failure cannot grant an in-memory enrollment") {
            try store.enrollVerifiedPeer(identity: other.publicIdentity, name: "Other", platform: "android", publicKey: other.publicKey)
        }
        store.enroll(identity: other.publicIdentity, name: "Other", platform: "android", publicKey: other.publicKey)
        check(!store.canTransfer(identity: other.publicIdentity), "Compatibility enrollment rolls back failed persistence")
        check(store.canTransfer(identity: peer.publicIdentity), "Failed persistence preserves existing enrollment")
        rejects(.trustStorageFailed, "Unpair cannot report success before persistence") {
            try store.unpairPersisted(identity: peer.publicIdentity)
        }
        check(store.canTransfer(identity: peer.publicIdentity), "Failed unpair restores the intended pin")
        check(try Data(contentsOf: backup) == savedBytes, "Failed write preserves previous stored bytes")
        check(lines.contains { $0.contains("NS-TRUST-004") }, "Storage failures produce a stable diagnostic code")
        check(!lines.joined().contains(root.path), "Storage diagnostics omit private paths")

        let corrupt = root.appendingPathComponent("corrupt.json")
        let privatePayload = Data("private corrupt payload".utf8)
        try privatePayload.write(to: corrupt)
        let corruptStore = PinnedTrustStore(customStorageURL: corrupt)
        rejects(.trustStorageFailed, "Corrupt storage cannot be silently replaced through enrollment") {
            try corruptStore.enrollVerifiedPeer(identity: peer.publicIdentity, name: "Peer", platform: "android", publicKey: peer.publicKey)
        }
        check(try Data(contentsOf: corrupt) == privatePayload, "Corrupt storage is preserved for recovery")
        check(!lines.joined().contains("private corrupt payload"), "Decoder diagnostics omit stored contents")

        let mismatch = root.appendingPathComponent("mismatch.json")
        let invalid = TrustedPeerRecord(identity: peer.publicIdentity, name: "Wrong", platformRaw: "android",
            spkiBase64: other.spkiDer.base64EncodedString(), enrolledAt: Date())
        try JSONEncoder().encode([invalid]).write(to: mismatch)
        let mismatchedStore = PinnedTrustStore(customStorageURL: mismatch)
        check(!mismatchedStore.canTransfer(identity: peer.publicIdentity), "Mismatched identity in legacy storage cannot grant trust")
        check(mismatchedStore.allEnrolledPeers().isEmpty, "Invalid storage is rejected as a complete snapshot")

        NearsideLogger.shared.logHandler = nil
        let parallelFile = root.appendingPathComponent("parallel.json")
        let parallel = PinnedTrustStore(customStorageURL: parallelFile)
        let peers = (0..<32).map { _ in DeviceIdentity() }
        DispatchQueue.concurrentPerform(iterations: peers.count) { index in
            let identity = peers[index]
            do {
                try parallel.enrollVerifiedPeer(identity: identity.publicIdentity, name: "Peer", platform: "android", publicKey: identity.publicKey)
                parallel.updatePeerEndpoint(identity: identity.publicIdentity, ip: "192.0.2.\(index + 1)", port: 41433)
                if index.isMultiple(of: 2) { parallel.block(identity: identity.publicIdentity) }
                _ = parallel.allEnrolledPeers()
            } catch { fatalError("Concurrent trust storage failed: \(error)") }
        }
        let reloaded = PinnedTrustStore(customStorageURL: parallelFile)
        check(reloaded.allEnrolledPeers().count == peers.count, "Concurrent trust transactions preserve every enrollment")
        check(peers.enumerated().allSatisfy { reloaded.canTransfer(identity: $0.element.publicIdentity) == !$0.offset.isMultiple(of: 2) },
            "Concurrent blocks and endpoint updates persist consistently")
        print("TrustStorageRegressionTests: 18 checks passed")
    }
    static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        print("PASS: \(message)")
    }
    static func rejects(_ code: NearsideErrorCode, _ message: String, body: () throws -> Void) {
        do { try body(); fatalError(message) }
        catch let error as NearsideError { check(error.code == code, message) }
        catch { fatalError("Unexpected error: \(error)") }
    }
}

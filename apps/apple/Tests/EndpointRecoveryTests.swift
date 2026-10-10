import Foundation
import Network
import CryptoKit

@main
struct EndpointRecoveryTests {
    static func main() {
        let identity = "ns1_target"
        let cached = NearsideDevice(id: identity, name: "MacBook", platform: .macOS,
            fingerprint: identity, ipAddress: "192.0.2.10", port: 41433)
        let live = NWEndpoint.service(name: "Nearside-MacBook (2)", type: "_nearside._tcp", domain: "local.", interface: nil)
        precondition(PeerEndpointRecovery.endpoint(for: cached, live: live) == live)
        let fallback = NWEndpoint.hostPort(host: "192.0.2.10", port: 41433)
        precondition(PeerEndpointRecovery.endpoint(for: cached, live: nil) == fallback)
        var invalid = cached
        invalid.fingerprint = "ns1_other"
        precondition(PeerEndpointRecovery.endpoint(for: invalid, live: live) == nil)
        invalid = cached
        invalid.ipAddress = nil
        precondition(PeerEndpointRecovery.endpoint(for: invalid, live: nil) == nil)
        invalid = cached
        invalid.port = 0
        precondition(PeerEndpointRecovery.endpoint(for: invalid, live: nil) == nil)

        let policy = RetryPolicy(maxAttempts: 3, initialDelay: 0)
        let offline = TransferEngineError.connectionFailed("offline")
        precondition(PeerEndpointRecovery.shouldRetry(error: offline, attempt: 1, policy: policy))
        precondition(PeerEndpointRecovery.shouldRetry(error: offline, attempt: 2, policy: policy))
        precondition(!PeerEndpointRecovery.shouldRetry(error: offline, attempt: 3, policy: policy))
        precondition(!PeerEndpointRecovery.shouldRetry(error: TransferEngineError.untrustedPeer(identity), attempt: 1, policy: policy))
        precondition(!PeerEndpointRecovery.shouldRetry(error: TransferEngineError.manifestRejected("denied"), attempt: 1, policy: policy))
        precondition(!PeerEndpointRecovery.shouldRetry(error: TransferEngineError.cancelled, attempt: 1, policy: policy))

        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let store = PinnedTrustStore(customStorageURL: path)
        let key = P256.Signing.PrivateKey().publicKey
        let peer = DeviceIdentity.computeIdentity(fromSpki: key.derRepresentation)
        store.enroll(identity: peer, name: "MacBook", platform: "macos", publicKey: key)
        store.updatePeerEndpoint(identity: peer, ip: "192.0.2.20", port: 42433)
        precondition(store.canTransfer(identity: peer))
        precondition(store.allEnrolledPeers().first?.spkiBase64 == key.derRepresentation.base64EncodedString())
        precondition(store.allEnrolledPeers().first?.lastKnownIp == "192.0.2.20")
        store.block(identity: peer)
        store.updatePeerEndpoint(identity: peer, ip: "192.0.2.30", port: 43433)
        precondition(!store.canTransfer(identity: peer))
        precondition(!PinnedTrustStore(customStorageURL: path).canTransfer(identity: peer))
        print("EndpointRecoveryTests: 17 checks passed")
    }
}

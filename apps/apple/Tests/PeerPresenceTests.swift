import Foundation
import CryptoKit

@main
struct PeerPresenceTests {
    private static var checks = 0

    static func main() throws {
        let first = DeviceIdentity()
        let second = DeviceIdentity()
        let third = DeviceIdentity()
        let old = peer(first, name: "Phone", host: "192.0.2.1", seen: 1)
        let current = peer(second, name: "Phone", host: "192.0.2.2", seen: 2)
        let nearby = peer(third, name: "Phone", host: "192.0.2.3", seen: 3)

        let startup = PeerPresenceSnapshot(trustedDevices: [old, current], discoveredDevices: [])
        check(startup.trustedDevices.count == 2, "Every distinct enrolled identity remains visible")
        check(startup.trustedDevices.allSatisfy { $0.reachability == .unreachable }, "Enrollment alone cannot mark a peer online")

        let online = PeerPresenceSnapshot(trustedDevices: startup.trustedDevices, discoveredDevices: [current, nearby])
        check(online.trustedDevices.first { $0.id == first.publicIdentity }?.reachability == .unreachable,
            "An older same-name enrollment stays offline")
        check(online.trustedDevices.first { $0.id == second.publicIdentity }?.reachability == .online,
            "Exact discovery identity brings its trusted peer online")
        check(online.availableNearbyDevices.map(\.id) == [third.publicIdentity], "Nearby section excludes only the matching trusted identity")
        check(online.discoveredDevices.count == 2, "Different identities with equal names stay separate")

        let refreshed = peer(second, name: "Changed unauthenticated name", host: "192.0.2.22", seen: 22)
        let aliases = PeerPresenceSnapshot(trustedDevices: [current], discoveredDevices: [current, refreshed, current])
        check(aliases.discoveredDevices.count == 1, "Multiple service announcements create one identity row")
        check(aliases.trustedDevices[0].ipAddress == "192.0.2.22", "Latest discovery refreshes the endpoint hint")
        check(aliases.trustedDevices[0].name == "Phone", "Discovery does not replace the enrolled display name")
        check(aliases.availableNearbyDevices.isEmpty, "Trusted aliases do not appear as unpaired nearby peers")

        let disappeared = PeerPresenceSnapshot(trustedDevices: aliases.trustedDevices, discoveredDevices: [])
        check(disappeared.trustedDevices[0].reachability == .unreachable, "Discovery disappearance marks the existing row offline")
        let returned = PeerPresenceSnapshot(trustedDevices: disappeared.trustedDevices, discoveredDevices: [refreshed])
        check(returned.trustedDevices.count == 1 && returned.trustedDevices[0].reachability == .online,
            "Reappearance updates the same trusted identity")
        var inconsistent = current
        inconsistent.fingerprint = first.publicIdentity
        let rejected = PeerPresenceSnapshot(trustedDevices: [old], discoveredDevices: [inconsistent])
        check(rejected.discoveredDevices.isEmpty && rejected.trustedDevices[0].reachability == .unreachable,
            "Mismatched discovery id and fingerprint cannot claim presence")
        var paused = current
        paused.reachability = .busy
        let pausedSnapshot = PeerPresenceSnapshot(trustedDevices: [current], discoveredDevices: [paused])
        check(pausedSnapshot.trustedDevices[0].reachability == .busy, "A peer with receiving paused is not a send recipient")

        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("NearsidePresenceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("trust.json")
        let store = PinnedTrustStore(customStorageURL: file)
        try store.enrollVerifiedPeer(identity: first.publicIdentity, name: "Phone", platform: "android", publicKey: first.publicKey)
        try store.enrollVerifiedPeer(identity: second.publicIdentity, name: "Phone", platform: "android", publicKey: second.publicKey)
        try store.unpairPersisted(identity: first.publicIdentity)
        let reloaded = PinnedTrustStore(customStorageURL: file)
        check(!reloaded.isEnrolled(identity: first.publicIdentity), "Unpair persists removal of the selected identity")
        check(reloaded.canTransfer(identity: second.publicIdentity), "Unpair preserves the distinct same-name peer")
        let afterUnpair = PeerPresenceSnapshot(trustedDevices: [current], discoveredDevices: [old, current])
        check(afterUnpair.availableNearbyDevices.map(\.id) == [first.publicIdentity], "An unpaired peer becomes available nearby while its sibling remains trusted")
        print("PeerPresenceTests: \(checks) checks passed")
    }

    private static func peer(_ identity: DeviceIdentity, name: String, host: String, seen: Double) -> NearsideDevice {
        NearsideDevice(id: identity.publicIdentity, name: name, platform: .android, fingerprint: identity.publicIdentity,
            ipAddress: host, port: 41433, reachability: .online, lastSeen: Date(timeIntervalSince1970: seen))
    }

    private static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        checks += 1
        print("PASS: \(message)")
    }
}

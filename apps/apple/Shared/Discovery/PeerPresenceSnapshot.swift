import Foundation

/// A discovery snapshot provides availability hints, never a new trust relationship.
public struct PeerPresenceSnapshot {
    public let trustedDevices: [NearsideDevice]
    public let discoveredDevices: [NearsideDevice]
    public let availableNearbyDevices: [NearsideDevice]

    public init(trustedDevices: [NearsideDevice], discoveredDevices: [NearsideDevice]) {
        let live = Self.uniqueDevices(discoveredDevices.filter {
            Self.hasConsistentIdentity($0) && $0.reachability != .unreachable
        })
        let liveByIdentity = Dictionary(uniqueKeysWithValues: live.map { ($0.fingerprint, $0) })
        let trusted = Self.uniqueDevices(trustedDevices.filter(Self.hasConsistentIdentity))
        let trustedIdentities = Set(trusted.map(\.fingerprint))

        self.trustedDevices = trusted.map { device in
            var updated = device
            if let current = liveByIdentity[device.fingerprint] {
                updated.reachability = current.reachability
                updated.ipAddress = current.ipAddress
                updated.port = current.port
                updated.lastSeen = current.lastSeen
            } else {
                updated.reachability = .unreachable
            }
            return updated
        }
        self.discoveredDevices = live
        self.availableNearbyDevices = live.filter { !trustedIdentities.contains($0.fingerprint) }
    }

    private static func hasConsistentIdentity(_ device: NearsideDevice) -> Bool {
        device.id == device.fingerprint &&
            device.fingerprint.range(of: "^ns1_[0-9a-f]{64}$", options: .regularExpression) != nil
    }

    private static func uniqueDevices(_ devices: [NearsideDevice]) -> [NearsideDevice] {
        var byIdentity: [String: NearsideDevice] = [:]
        for device in devices {
            if let previous = byIdentity[device.fingerprint], previous.lastSeen > device.lastSeen {
                continue
            }
            byIdentity[device.fingerprint] = device
        }
        return byIdentity.values.sorted {
            let order = $0.name.localizedCaseInsensitiveCompare($1.name)
            return order == .orderedSame ? $0.fingerprint < $1.fingerprint : order == .orderedAscending
        }
    }
}

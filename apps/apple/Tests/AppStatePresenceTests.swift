import Foundation
import CryptoKit
import AppKit
import SwiftUI

@main
struct AppStatePresenceTests {
    private static var checks = 0

    @MainActor
    static func main() throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("NearsideAppStateTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        if CommandLine.arguments.contains("--render-shelf") {
            try renderShelf(root: root)
            return
        }
        let file = root.appendingPathComponent("trust.json")
        let store = PinnedTrustStore(customStorageURL: file)
        let local = DeviceIdentity()
        let oldPhone = DeviceIdentity()
        let phone = DeviceIdentity()
        let stranger = DeviceIdentity()
        try store.enrollVerifiedPeer(identity: oldPhone.publicIdentity, name: "Phone", platform: "android", publicKey: oldPhone.publicKey)
        try store.enrollVerifiedPeer(identity: phone.publicIdentity, name: "Phone", platform: "android", publicKey: phone.publicKey)
        let state = AppState(deviceIdentity: local, trustStore: store, startsDiscovery: false)
        check(state.pairedDevices.count == 2 && state.pairedDevices.allSatisfy { $0.reachability == .unreachable },
            "AppState loads existing trust as offline without starting discovery")
        check(state.onlineTransferRecipients.isEmpty, "Offline trusted peers are excluded from shelf recipients")
        let livePhone = device(phone)
        let liveStranger = device(stranger)
        state.updateDiscoveryPresence([livePhone, livePhone, liveStranger])
        check(state.pairedDevices.count == 2 && state.discoveredDevices.count == 2, "AppState deduplicates service aliases without deleting a stale identity")
        check(state.onlineTransferRecipients.map(\.id) == [phone.publicIdentity], "Only the exact online trusted identity can be selected for sending")
        check(state.availableNearbyDevices.map(\.id) == [stranger.publicIdentity], "An untrusted discovery is available for pairing and excluded from sending")
        check(state.pairedDevices.first { $0.id == oldPhone.publicIdentity }?.reachability == .unreachable,
            "The older same-name identity remains offline")
        state.updateDiscoveryPresence([])
        check(state.pairedDevices.allSatisfy { $0.reachability == .unreachable }, "Discovery loss updates trusted availability immediately")
        state.updateDiscoveryPresence([livePhone])
        check(state.onlineTransferRecipients.map(\.id) == [phone.publicIdentity], "Reappearance restores the existing trusted recipient")
        store.block(identity: phone.publicIdentity)
        check(state.onlineTransferRecipients.isEmpty, "An online blocked peer never becomes a shelf transfer recipient")

        let backup = root.appendingPathComponent("saved.json")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        var lines: [String] = []
        NearsideLogger.shared.logHandler = { lines.append($0) }
        defer { NearsideLogger.shared.logHandler = nil }
        if case .success = state.unpairDevice(id: oldPhone.publicIdentity) { fatalError("Failed storage must reject unpair") }
        check(state.pairedDevices.count == 2 && store.isEnrolled(identity: oldPhone.publicIdentity),
            "A failed durable unpair preserves both the UI row and trusted key")
        check(lines.contains { $0.contains("NS-TRUST-004") && $0.contains("correlationId=") && $0.contains("unpairDevice") },
            "Unpair failure has a stable error code, operation, and correlation ID")
        check(!lines.joined().contains(root.path), "Unpair diagnostics omit private storage paths")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        try state.unpairDevice(id: oldPhone.publicIdentity).get()
        check(state.pairedDevices.map(\.id) == [phone.publicIdentity], "Successful unpair removes only the selected identity immediately")
        let reloaded = PinnedTrustStore(customStorageURL: file)
        check(!reloaded.isEnrolled(identity: oldPhone.publicIdentity) && reloaded.isEnrolled(identity: phone.publicIdentity),
            "Only the selected trust relationship is removed after restart")
        check(reloaded.isBlocked(identity: phone.publicIdentity), "Unpair preserves another peer's blocked state")
        print("AppStatePresenceTests: \(checks) checks passed")
    }

    @MainActor
    private static func renderShelf(root: URL) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let local = DeviceIdentity()
        let oldPhone = DeviceIdentity()
        let phone = DeviceIdentity()
        let tablet = DeviceIdentity()
        let store = PinnedTrustStore(customStorageURL: root.appendingPathComponent("preview-trust.json"))
        try store.enrollVerifiedPeer(identity: oldPhone.publicIdentity, name: "Phone", platform: "android", publicKey: oldPhone.publicKey)
        try store.enrollVerifiedPeer(identity: phone.publicIdentity, name: "Phone", platform: "android", publicKey: phone.publicKey)
        let state = AppState(deviceIdentity: local, trustStore: store, startsDiscovery: false)
        var nearby = device(tablet)
        nearby.name = "Nearby Tablet"
        nearby = NearsideDevice(id: tablet.publicIdentity, name: nearby.name, platform: .iOS,
            fingerprint: tablet.publicIdentity, ipAddress: "192.0.2.6", port: 41433)
        state.updateDiscoveryPresence([device(phone), nearby])
        let hosting = NSHostingView(rootView: MenuBarShelfView(appState: state)
            .environment(\.colorScheme, .light)
            .background(Color(nsColor: .windowBackgroundColor)))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 350, height: 420),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = hosting
        window.setContentSize(NSSize(width: 350, height: 420))
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        guard let bitmap = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            fatalError("Could not allocate the shelf preview")
        }
        hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            fatalError("Could not render the shelf preview")
        }
        window.orderOut(nil)
        let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/app-state-presence-tests/ShelfPreview.png")
        try data.write(to: output)
        print("Shelf preview: \(output.path) (\(hosting.bounds.width) x \(hosting.bounds.height))")
    }

    private static func device(_ identity: DeviceIdentity) -> NearsideDevice {
        NearsideDevice(id: identity.publicIdentity, name: "Phone", platform: .android,
            fingerprint: identity.publicIdentity, ipAddress: "192.0.2.5", port: 41433)
    }

    private static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        checks += 1
        print("PASS: \(message)")
    }
}

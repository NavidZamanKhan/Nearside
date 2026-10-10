import AppKit
import SwiftUI

/// Document imports are untrusted. Sending always requires a fresh user action
/// in the host, using its current trust store and persistent signing identity.
@MainActor
final class HostShareController: NSObject, NSWindowDelegate, ObservableObject {
    private static var sessions: [HostShareController] = []
    private let imported: ImportedMacShare
    private var window: NSWindow?
    @Published private(set) var isTransferring = false
    @Published private(set) var progress = 0.0
    @Published private(set) var errorMessage: String?
    @Published private(set) var completed = false

    var files: [URL] { imported.files }

    private init(imported: ImportedMacShare) {
        self.imported = imported
        super.init()
    }

    static func open(requestURL: URL) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("NearsideHostShares", isDirectory: true)
        MacShareHandoff.removeExpiredRequests(in: root,
            excluding: Set(sessions.map { $0.imported.directory.standardizedFileURL }))
        do {
            let imported = try MacShareHandoff.importRequest(at: requestURL, into: root)
            do { try MacShareHandoff.acknowledge(imported, requestURL: requestURL) }
            catch {
                try? FileManager.default.removeItem(at: imported.directory)
                throw error
            }
            let controller = HostShareController(imported: imported)
            sessions.append(controller)
            controller.show()
            NearsideLogger.shared.info("share", "importShareRequest", "Shared files imported; waiting for recipient confirmation",
                state: "awaitingConfirmation", correlationId: imported.request.id,
                metadata: ["filesCount": "\(imported.files.count)"])
        } catch {
            let failure = (error as? NearsideError) ?? MacShareHandoff.failure(.storageReadFailed,
                "Could not import the shared files. Return to the share sheet and try again.", cause: error)
            NearsideLogger.shared.error(failure, state: "failed")
            let alert = NSAlert()
            alert.messageText = "Unable to prepare share"
            alert.informativeText = failure.localizedDescription
            alert.runModal()
        }
    }

    private func show() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 380),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Share with Nearside"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = NSHostingView(rootView: HostSharePicker(controller: self, state: AppState.shared))
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func send(to device: NearsideDevice) {
        guard !isTransferring, !completed else { return }
        let state = AppState.shared
        guard state.trustStore.canTransfer(identity: device.id) else {
            errorMessage = "This device is no longer paired. Pair it in Nearside first."
            return
        }
        isTransferring = true
        progress = 0
        errorMessage = nil
        TransferEngine.shared.sendFiles(files: imported.files, to: device,
            senderId: state.deviceIdentity.publicIdentity, trustStore: state.trustStore,
            onProgress: { [weak self] fraction, _, _ in
                Task { @MainActor in self?.progress = fraction }
            }, completion: { [weak self] result in
                Task { @MainActor in
                    guard let self else { return }
                    self.isTransferring = false
                    switch result {
                    case .success(let record):
                        state.transferHistory.insert(record, at: 0)
                        self.completed = true
                        self.progress = 1
                        self.cleanupFiles()
                        NearsideLogger.shared.info("share", "sendHostShare", "Share transfer completed",
                            state: "completed", correlationId: self.imported.request.id)
                    case .failure(let error):
                        let failure = (error as? NearsideError)
                            ?? (error as? TransferEngineError)?.toNearsideError(operation: "sendHostShare", correlationId: self.imported.request.id)
                            ?? MacShareHandoff.failure(.transferInterrupted,
                                "Share transfer failed. Check the recipient's connection and try again.",
                                id: self.imported.request.id, cause: error)
                        self.errorMessage = failure.localizedDescription
                        NearsideLogger.shared.error(failure, state: "failed")
                        // Retain host copies for retry; close/expiry removes them.
                    }
                }
            })
    }

    func close() { if !isTransferring { window?.close() } }
    func windowShouldClose(_ sender: NSWindow) -> Bool { !isTransferring }
    func windowWillClose(_ notification: Notification) {
        cleanupFiles()
        Self.sessions.removeAll { $0 === self }
    }
    private func cleanupFiles() { try? FileManager.default.removeItem(at: imported.directory) }
}

private struct HostSharePicker: View {
    @ObservedObject var controller: HostShareController
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(controller.completed ? "Delivered" : "Choose a paired device").font(.headline)
            Text(controller.files.map(\.lastPathComponent).joined(separator: ", "))
                .lineLimit(3).font(.caption).foregroundStyle(.secondary)
            if let error = controller.errorMessage {
                Text(error).foregroundStyle(.red).font(.caption)
            }
            if controller.isTransferring {
                ProgressView(value: controller.progress)
                Text("Keep Nearside open until the transfer completes.").font(.caption)
            } else if !controller.completed {
                if state.pairedDevices.isEmpty {
                    Text("Pair a device in Nearside, then return to this window.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 16)
                } else if state.onlineTransferRecipients.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("No paired devices are currently online on Wi-Fi.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Text("Make sure Nearside is running on your phone and connected to the same Wi-Fi network.")
                            .font(.caption)
                            .foregroundColor(.secondary.opacity(0.8))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 16)
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(state.onlineTransferRecipients) { device in
                                Button {
                                    controller.send(to: device)
                                } label: {
                                    HStack(spacing: 10) {
                                        Image(systemName: device.platform.systemSymbolName)
                                            .font(.system(size: 16))
                                            .foregroundColor(.accentColor)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(device.name)
                                                .font(.system(size: 13, weight: .medium))
                                            HStack(spacing: 4) {
                                                Circle()
                                                    .fill(Color.green)
                                                    .frame(width: 6, height: 6)
                                                Text("Online • \(device.shortFingerprint)")
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                            }
                                        }
                                        Spacer()
                                        Text("Send")
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundColor(.accentColor)
                                    }
                                    .padding(8)
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }
            Spacer()
            HStack {
                Spacer()
                Button(controller.completed ? "Done" : "Cancel") { controller.close() }
                    .disabled(controller.isTransferring)
            }
        }
        .padding(20)
        .frame(width: 480, height: 380)
    }
}

import SwiftUI
import AppKit

@MainActor
public struct MenuBarShelfView: View {
    @ObservedObject var appState: AppState
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

    @State private var isDropzoneTargeted: Bool = false
    @State private var droppedURLs: [URL] = []
    @State private var showRecipientPicker: Bool = false
    @State private var pairingRequest: ShelfPairingRequest?
    @State private var unpairCandidate: NearsideDevice?

    public init(
        appState: AppState,
        onOpenSettings: @escaping () -> Void = {},
        onQuit: @escaping () -> Void = {}
    ) {
        self.appState = appState
        self.onOpenSettings = onOpenSettings
        self.onQuit = onQuit
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header & Master Receiving Switch Hero Card
            headerHeroCard
                .padding(.horizontal, 14)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Button {
                pairingRequest = ShelfPairingRequest(target: nil)
            } label: {
                Label("Pair Device / Show QR", systemImage: "qrcode")
                    .font(.system(size: 11, weight: .medium))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .padding(.horizontal, 14)
            .padding(.bottom, 10)

            Divider()

            // Active Transfer Live Progress (if running)
            if let active = appState.activeTransfer {
                activeTransferCard(record: active)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                Divider()
            }

            // Clipboard Action Feedback Banner
            if let toast = appState.clipboardToastMessage {
                HStack(spacing: 6) {
                    Image(systemName: "doc.on.clipboard.fill")
                        .font(.system(size: 11))
                        .foregroundColor(.accentColor)
                    Text(toast)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.12))
                Divider()
            }

            // Main scrollable content
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    // Universal Quick Dropzone
                    universalDropzoneCard

                    trustedDevicesSection
                    nearbyDevicesSection

                    // Recent Transfers History
                    recentTransfersSection
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .frame(maxHeight: .infinity)

            Divider()

            // Footer Toolbar
            footerToolbar
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
        }
        .frame(width: 350, height: 420)
        .sheet(isPresented: $showRecipientPicker) {
            recipientPickerSheet
        }
        .sheet(item: $pairingRequest) { request in
            MacPairingView(appState: appState, target: request.target)
        }
        .confirmationDialog("Unpair \(unpairCandidate?.name ?? "device")?", isPresented: Binding(
            get: { unpairCandidate != nil },
            set: { if !$0 { unpairCandidate = nil } }
        ), titleVisibility: .visible, presenting: unpairCandidate) { device in
            Button("Unpair", role: .destructive) {
                appState.unpairDevice(id: device.fingerprint)
                unpairCandidate = nil
            }
            Button("Cancel", role: .cancel) { unpairCandidate = nil }
        } message: { device in
            Text("Remove trust for identity \(device.shortFingerprint)? Pair this device again before sending or receiving content.")
        }
    }

    // MARK: - Master Switch Hero Card
    private var headerHeroCard: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(appState.isReceivingActive ? Color.green.opacity(0.2) : Color.secondary.opacity(0.12))
                    .frame(width: 38, height: 38)
                Image(systemName: appState.isReceivingActive ? "antenna.radiowaves.left.and.right" : "moon.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(appState.isReceivingActive ? .green : .secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Nearside Receiving")
                        .font(.system(size: 13, weight: .bold))
                    Circle()
                        .fill(appState.isReceivingActive ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 6, height: 6)
                }
                Text(appState.isReceivingActive ? "Ready • Listening on port 41433" : "Dormant • 0% CPU • Zero Battery")
                    .font(.system(size: 10))
                    .foregroundColor(appState.isReceivingActive ? .secondary : Color.secondary.opacity(0.8))
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { appState.isReceivingActive },
                set: { _ in
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        appState.toggleReceiving()
                    }
                }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.mini)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(appState.isReceivingActive ? Color.green.opacity(0.25) : Color.secondary.opacity(0.12), lineWidth: 1)
        )
    }

    // MARK: - Universal Drag & Drop Dropzone
    private var universalDropzoneCard: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: isDropzoneTargeted ? "arrow.down.doc.fill" : "square.and.arrow.up")
                    .font(.system(size: 14))
                    .foregroundColor(isDropzoneTargeted ? .accentColor : .secondary)

                VStack(alignment: .leading, spacing: 1) {
                    Text(isDropzoneTargeted ? "Release to Send Files" : "Drop files here to send")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(isDropzoneTargeted ? .accentColor : .primary)
                    Text("Or right-click any file in Finder -> Share -> Nearside")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isDropzoneTargeted ? Color.accentColor.opacity(0.12) : Color(nsColor: .quaternaryLabelColor).opacity(0.2))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isDropzoneTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                    style: StrokeStyle(lineWidth: 1, dash: [4, 4])
                )
        )
        .onDrop(of: [.fileURL], isTargeted: $isDropzoneTargeted) { providers in
            handleDroppedFiles(providers: providers)
            return true
        }
    }

    // MARK: - Active Transfer Card
    private func activeTransferCard(record: TransferRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: record.fileIconName)
                        .font(.system(size: 14))
                        .foregroundColor(.accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(record.direction == .outgoing ? "Sending to" : "Receiving from")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text(record.deviceName)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.primary)
                    }
                    Text(record.filename)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                }

                Spacer()

                Button(action: {
                    appState.cancelActiveTransfer()
                }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Cancel Transfer")
            }

            ProgressView(value: record.progress)
                .progressViewStyle(.linear)
                .controlSize(.small)

            HStack {
                Text("\(record.formattedBytesTransferred) of \(record.formattedSize)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)

                Spacer()

                if !record.formattedSpeed.isEmpty {
                    Text(record.formattedSpeed)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(.accentColor)
                }

                if !record.estimatedTimeRemaining.isEmpty {
                    Text("• \(record.estimatedTimeRemaining)")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.8))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.accentColor.opacity(0.3), lineWidth: 1)
        )
    }

    private var displayPairedDevices: [NearsideDevice] {
        let onlineDevices = appState.onlineTransferRecipients
        return appState.pairedDevices.filter { device in
            if device.reachability == .online { return true }
            let hasOnlineSameName = onlineDevices.contains {
                $0.name.lowercased() == device.name.lowercased() && $0.platform == device.platform
            }
            return !hasOnlineSameName
        }
    }

    private var trustedDevicesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeading("TRUSTED DEVICES", count: displayPairedDevices.count)
            if displayPairedDevices.isEmpty {
                Text("No paired devices yet")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                VStack(spacing: 4) {
                    ForEach(displayPairedDevices) { device in
                        DeviceRowView(device: device, isTrusted: true,
                            isBlocked: appState.trustStore.isBlocked(identity: device.fingerprint),
                            canSend: appState.onlineTransferRecipients.contains { $0.fingerprint == device.fingerprint },
                            onSend: { promptSendFile(to: device) },
                            onSendClipboard: { sendClipboardIfAvailable(to: device) },
                            onDropFiles: { urls in sendFilesIfAvailable(urls, to: device) },
                            onPair: {}, onUnpair: { unpairCandidate = device })
                    }
                }
            }
        }
    }

    private var nearbyDevicesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionHeading("AVAILABLE NEARBY", count: appState.availableNearbyDevices.count)
            if appState.availableNearbyDevices.isEmpty {
                VStack(spacing: 4) {
                    Text("No unpaired devices nearby")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if !appState.isReceivingActive {
                        Text("Turn on Receiving to discover peers on Wi-Fi")
                            .font(.system(size: 9))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 4) {
                    ForEach(appState.availableNearbyDevices) { device in
                        DeviceRowView(device: device, isTrusted: false, isBlocked: false, canSend: false,
                            onSend: {}, onSendClipboard: {}, onDropFiles: { _ in },
                            onPair: { pairingRequest = ShelfPairingRequest(target: device) }, onUnpair: {})
                    }
                }
            }
        }
    }

    private func sectionHeading(_ title: String, count: Int) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 10, weight: .bold))
            Spacer()
            Text("\(count)")
                .font(.caption2)
        }
        .foregroundColor(.secondary)
        .padding(.horizontal, 2)
    }

    // MARK: - Recent Transfers Section
    private var recentTransfersSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("RECENT ACTIVITY")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                if !appState.transferHistory.isEmpty {
                    Button(action: { appState.clearHistory() }) {
                        Text("Clear")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            .padding(.horizontal, 2)

            if appState.transferHistory.isEmpty {
                HStack {
                    Spacer()
                    Text("No recent transfers")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 8)
                    Spacer()
                }
            } else {
                VStack(spacing: 3) {
                    ForEach(appState.transferHistory) { record in
                        TransferRowView(
                            record: record,
                            downloadsURL: appState.downloadsFolderURL
                        )
                    }
                }
            }
        }
    }

    // MARK: - Footer Toolbar
    private var footerToolbar: some View {
        HStack {
            Button(action: onOpenSettings) {
                Label("Settings", systemImage: "gearshape")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)

            Spacer()

            Button(action: {
                NSWorkspace.shared.open(appState.downloadsFolderURL)
            }) {
                Label("Downloads", systemImage: "folder")
                    .font(.system(size: 11))
            }
            .buttonStyle(.borderless)

            Spacer()

            Button(action: onQuit) {
                Text("Quit")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: - Recipient Picker Sheet
    private var recipientPickerSheet: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Select Recipient")
                    .font(.system(size: 13, weight: .bold))
                Spacer()
                Button("Cancel") {
                    showRecipientPicker = false
                    droppedURLs.removeAll()
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }

            Text("\(droppedURLs.count) file(s) selected")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            if appState.onlineTransferRecipients.isEmpty {
                Text("No trusted devices are online")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 20)
            } else {
                VStack(spacing: 6) {
                    ForEach(appState.onlineTransferRecipients) { device in
                        Button(action: {
                            let urls = droppedURLs
                            showRecipientPicker = false
                            droppedURLs.removeAll()
                            sendFilesIfAvailable(urls, to: device)
                        }) {
                            HStack(spacing: 10) {
                                Image(systemName: device.platform.systemSymbolName)
                                    .font(.system(size: 14))
                                    .foregroundColor(.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name)
                                        .font(.system(size: 12, weight: .medium))
                                    Text(device.platform.displayName)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Image(systemName: "paperplane.fill")
                                    .font(.system(size: 11))
                                    .foregroundColor(.accentColor)
                            }
                            .padding(8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.3))
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    private func handleDroppedFiles(providers: [NSItemProvider]) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()

        for provider in providers {
            group.enter()
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let fileURL = url {
                    lock.lock()
                    urls.append(fileURL)
                    lock.unlock()
                }
                group.leave()
            }
        }

        group.notify(queue: .main) {
            guard !urls.isEmpty else { return }
            let peers = self.appState.onlineTransferRecipients
            if peers.count == 1, let singleDevice = peers.first {
                self.sendFilesIfAvailable(urls, to: singleDevice)
            } else {
                self.droppedURLs = urls
                self.showRecipientPicker = true
            }
        }
    }

    private func availableRecipient(_ device: NearsideDevice) -> NearsideDevice? {
        guard let live = appState.onlineTransferRecipients.first(where: { $0.fingerprint == device.fingerprint }) else {
            let failure = NearsideError(code: .discoveryResolveFailed, operation: "shelfSend",
                message: "Selected trusted device is not available. Wait for it to appear online.",
                correlationId: UUID().uuidString)
            NearsideLogger.shared.error(failure, state: "unavailable")
            appState.clipboardToastMessage = "Device is offline [\(failure.code.rawValue)]"
            return nil
        }
        return live
    }

    private func sendFilesIfAvailable(_ urls: [URL], to device: NearsideDevice) {
        guard let live = availableRecipient(device) else { return }
        appState.sendFiles(urls: urls, to: live)
    }

    private func sendClipboardIfAvailable(to device: NearsideDevice) {
        guard let live = availableRecipient(device) else { return }
        appState.sendClipboard(to: live)
    }

    private func promptSendFile(to device: NearsideDevice) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Send"
        panel.title = "Send to \(device.name)"

        if panel.runModal() == .OK {
            sendFilesIfAvailable(panel.urls, to: device)
        }
    }
}

private struct ShelfPairingRequest: Identifiable {
    let id = UUID()
    let target: NearsideDevice?
}

// MARK: - Native AppKit-Style Device Row
private struct DeviceRowView: View {
    let device: NearsideDevice
    let isTrusted: Bool
    let isBlocked: Bool
    let canSend: Bool
    let onSend: () -> Void
    let onSendClipboard: () -> Void
    let onDropFiles: ([URL]) -> Void
    let onPair: () -> Void
    let onUnpair: () -> Void
    @State private var isHovered: Bool = false
    @State private var isDropTarget: Bool = false

    private var presenceColor: Color {
        isTrusted ? (device.reachability == .online && !isBlocked ? .green : .gray) : .accentColor
    }

    private var presenceLabel: String {
        guard isTrusted else { return "Nearby / Not paired" }
        if isBlocked { return "Trusted / Blocked" }
        switch device.reachability {
        case .online: return "Trusted / Online"
        case .busy: return "Trusted / Receiving paused"
        case .unreachable: return "Trusted / Offline"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(isDropTarget ? Color.accentColor.opacity(0.3) : Color.accentColor.opacity(0.12))
                    .frame(width: 32, height: 32)
                Image(systemName: isDropTarget ? "arrow.down.doc.fill" : device.platform.systemSymbolName)
                    .font(.system(size: 14))
                    .foregroundColor(.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Circle()
                        .fill(presenceColor)
                        .frame(width: 5, height: 5)
                    Text(presenceLabel)
                }
                .font(.system(size: 9))
                .foregroundColor(.secondary)
                HStack(spacing: 4) {
                    Text(device.platform.displayName)
                    Text("•")
                    Text(device.shortFingerprint)
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }

            Spacer()

            if isTrusted {
                Button(action: onSendClipboard) {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!canSend)
                .help(canSend ? "Send clipboard to \(device.name)" : "Device is unavailable")

                Button("Send...", action: onSend)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!canSend)

                Button(action: onUnpair) {
                    Image(systemName: "person.crop.circle.badge.xmark")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)
                .help("Unpair \(device.name) (\(device.shortFingerprint))")
                .accessibilityLabel("Unpair \(device.name)")
            } else {
                Button("Pair", action: onPair)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isDropTarget ? Color.accentColor.opacity(0.15) : (isHovered ? Color(nsColor: .quaternaryLabelColor) : Color.clear))
        )
        .onHover { inside in
            isHovered = inside
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTarget) { providers in
            guard canSend else { return false }
            let group = DispatchGroup()
            var collectedURLs: [URL] = []
            let lock = NSLock()

            for provider in providers {
                group.enter()
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let fileURL = url {
                        lock.lock()
                        collectedURLs.append(fileURL)
                        lock.unlock()
                    }
                    group.leave()
                }
            }

            group.notify(queue: .main) {
                if !collectedURLs.isEmpty {
                    onDropFiles(collectedURLs)
                }
            }
            return true
        }
    }
}

// MARK: - Native AppKit-Style Transfer Row
private struct TransferRowView: View {
    let record: TransferRecord
    let downloadsURL: URL
    @State private var isHovered: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            let iconColor: Color = {
                if record.status == .failed || record.status == .cancelled { return .red }
                if record.payloadType == .url { return .blue }
                if record.payloadType == .text { return .purple }
                return record.direction == .incoming ? .green : .accentColor
            }()

            Image(systemName: record.fileIconName)
                .symbolRenderingMode(.hierarchical)
                .foregroundColor(iconColor)
                .font(.system(size: 15))

            VStack(alignment: .leading, spacing: 2) {
                Text(record.filename)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(record.deviceName)
                    Text("•")
                    Text(record.formattedSize)
                    if let code = record.errorCode {
                        Text("•")
                        Text(code)
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.red)
                    }
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }

            Spacer()

            if record.payloadType == .url, let text = record.payloadText, let url = URL(string: text) {
                Button(action: {
                    NSWorkspace.shared.open(url)
                }) {
                    Image(systemName: "arrow.up.right.square")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Open in Browser")
            } else if record.direction == .incoming && record.status == .completed {
                Button(action: {
                    NSWorkspace.shared.activateFileViewerSelecting([
                        downloadsURL.appendingPathComponent(record.filename)
                    ])
                }) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? Color(nsColor: .quaternaryLabelColor) : Color.clear)
        )
        .onHover { inside in
            isHovered = inside
        }
    }
}

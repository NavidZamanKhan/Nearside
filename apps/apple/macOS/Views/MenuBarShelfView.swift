import SwiftUI
import AppKit

@MainActor
public struct MenuBarShelfView: View {
    @ObservedObject var appState: AppState
    var onOpenSettings: () -> Void
    var onQuit: () -> Void

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
            // Header
            headerSection
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 12)

            Divider()

            // Active Transfer Live Progress (if running)
            if let active = appState.activeTransfer {
                activeTransferSection(record: active)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                Divider()
            }

            // Main scrollable content
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 14) {
                    nearbyDevicesSection
                    recentTransfersSection
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
            }
            .frame(maxHeight: 360)

            Divider()

            // Footer Toolbar
            footerToolbar
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
        }
        .frame(width: 340)
    }

    // MARK: - Header
    private var headerSection: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Nearside")
                        .font(.system(size: 14, weight: .bold))
                    Circle()
                        .fill(appState.isReceivingActive ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                }
                Text(appState.localDeviceName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: {
                appState.toggleReceiving()
            }) {
                HStack(spacing: 4) {
                    Image(systemName: appState.isReceivingActive ? "antenna.radiowaves.left.and.right" : "moon.fill")
                        .font(.system(size: 10))
                    Text(appState.isReceivingActive ? "Receiving" : "Paused")
                        .font(.system(size: 11, weight: .medium))
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(appState.isReceivingActive ? .green : .orange)
        }
    }

    // MARK: - Active Transfer
    private func activeTransferSection(record: TransferRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "arrow.up.circle.fill")
                    .symbolRenderingMode(.hierarchical)
                    .foregroundColor(.accentColor)
                    .font(.system(size: 14))

                Text("Sending to \(record.deviceName)...")
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(Int(record.progress * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Text(record.filename)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
            ProgressView(value: record.progress)
                .progressViewStyle(.linear)
                .controlSize(.small)
        }
    }

    // MARK: - Nearby Devices Section
    private var nearbyDevicesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("AVAILABLE PEERS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(appState.discoveredDevices.count) nearby")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 4)

            if appState.discoveredDevices.isEmpty {
                HStack {
                    Spacer()
                    Text("No nearby devices advertising")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 10)
                    Spacer()
                }
            } else {
                VStack(spacing: 2) {
                    ForEach(appState.discoveredDevices) { device in
                        DeviceRowView(
                            device: device,
                            onSend: { promptSendFile(to: device) },
                            onDropFiles: { urls in appState.sendFiles(urls: urls, to: device) }
                        )
                    }
                }
            }
        }
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
            .padding(.horizontal, 4)

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
                VStack(spacing: 2) {
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

    private func promptSendFile(to device: NearsideDevice) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Send"
        panel.title = "Send to \(device.name)"

        if panel.runModal() == .OK {
            appState.sendFiles(urls: panel.urls, to: device)
        }
    }
}

// MARK: - Native AppKit-Style Device Row
private struct DeviceRowView: View {
    let device: NearsideDevice
    let onSend: () -> Void
    let onDropFiles: ([URL]) -> Void
    @State private var isHovered: Bool = false
    @State private var isDropTarget: Bool = false

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
                HStack(spacing: 4) {
                    Text(device.platform.displayName)
                    Text("•")
                    Text(device.shortFingerprint)
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }

            Spacer()

            Button("Send File...", action: onSend)
                .buttonStyle(.bordered)
                .controlSize(.small)
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
            Image(systemName: record.direction == .incoming ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundColor(record.direction == .incoming ? .green : .accentColor)
                .font(.system(size: 15))

            VStack(alignment: .leading, spacing: 2) {
                Text(record.filename)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(record.deviceName)
                    Text("•")
                    Text(record.formattedSize)
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }

            Spacer()

            if record.direction == .incoming {
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

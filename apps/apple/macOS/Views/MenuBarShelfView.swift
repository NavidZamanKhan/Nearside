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
                .padding(.vertical, 14)

            Divider()

            // Active Transfer (if running)
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
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .frame(maxHeight: 380)

            Divider()

            // Bottom toolbar
            footerToolbar
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color(NSColor.windowBackgroundColor).opacity(0.6))
        }
        .frame(width: 350)
    }

    // MARK: - Header
    private var headerSection: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("Nearside")
                        .font(.system(size: 15, weight: .bold))
                    Circle()
                        .fill(appState.isReceivingActive ? Color.green : Color.orange)
                        .frame(width: 8, height: 8)
                }
                Text(appState.localDeviceName)
                    .font(.system(size: 11))
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
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(appState.isReceivingActive ? Color.green.opacity(0.15) : Color.orange.opacity(0.15))
                .foregroundColor(appState.isReceivingActive ? .green : .orange)
                .cornerRadius(12)
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Active Transfer
    private func activeTransferSection(record: TransferRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundColor(.blue)
                Text("Sending to \(record.deviceName)...")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(Int(record.progress * 100))%")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Text(record.filename)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(1)
            ProgressView(value: record.progress)
                .progressViewStyle(.linear)
        }
    }

    // MARK: - Nearby Devices
    private var nearbyDevicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("AVAILABLE PEERS")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(appState.discoveredDevices.count) nearby")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            if appState.discoveredDevices.isEmpty {
                HStack {
                    Spacer()
                    Text("No nearby devices advertising")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 8)
                    Spacer()
                }
            } else {
                ForEach(appState.discoveredDevices) { device in
                    deviceRow(device: device)
                }
            }
        }
    }

    private func deviceRow(device: NearsideDevice) -> some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 32, height: 32)
                Image(systemName: device.platform.systemSymbolName)
                    .font(.system(size: 14))
                    .foregroundColor(.accentColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.system(size: 12, weight: .medium))
                HStack(spacing: 4) {
                    Text(device.platform.displayName)
                    Text("•")
                    Text(device.shortFingerprint)
                }
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            }

            Spacer()

            Button(action: {
                promptSendFile(to: device)
            }) {
                Text("Send File...")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.08))
                    .cornerRadius(6)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    // MARK: - Recent Transfers
    private var recentTransfersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("RECENT ACTIVITY")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.secondary)
                Spacer()
                if !appState.transferHistory.isEmpty {
                    Button(action: { appState.clearHistory() }) {
                        Text("Clear")
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }

            if appState.transferHistory.isEmpty {
                HStack {
                    Spacer()
                    Text("No recent transfers")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .padding(.vertical, 8)
                    Spacer()
                }
            } else {
                ForEach(appState.transferHistory) { record in
                    transferRow(record: record)
                }
            }
        }
    }

    private func transferRow(record: TransferRecord) -> some View {
        HStack(spacing: 8) {
            Image(systemName: record.direction == .incoming ? "arrow.down.circle.fill" : "arrow.up.circle.fill")
                .foregroundColor(record.direction == .incoming ? .green : .blue)
                .font(.system(size: 14))

            VStack(alignment: .leading, spacing: 2) {
                Text(record.filename)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(record.deviceName)
                    Text("•")
                    Text(record.formattedSize)
                }
                .font(.system(size: 9))
                .foregroundColor(.secondary)
            }

            Spacer()

            if record.direction == .incoming {
                Button(action: {
                    NSWorkspace.shared.activateFileViewerSelecting([
                        appState.downloadsFolderURL.appendingPathComponent(record.filename)
                    ])
                }) {
                    Image(systemName: "folder")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .help("Show in Finder")
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Footer Toolbar
    private var footerToolbar: some View {
        HStack {
            Button(action: onOpenSettings) {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
                Text("Settings")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: {
                NSWorkspace.shared.open(appState.downloadsFolderURL)
            }) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                Text("Downloads")
                    .font(.system(size: 11))
            }
            .buttonStyle(.plain)

            Spacer()

            Button(action: onQuit) {
                Text("Quit")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            .buttonStyle(.plain)
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
            let urls = panel.urls
            let filenames = urls.map { $0.lastPathComponent }
            let totalBytes = urls.reduce(Int64(0)) { acc, url in
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 1024
                return acc + Int64(size)
            }
            appState.simulateOutgoingTransfer(to: device, filenames: filenames, totalBytes: totalBytes)
        }
    }
}

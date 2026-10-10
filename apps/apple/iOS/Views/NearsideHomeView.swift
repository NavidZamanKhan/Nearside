import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

public struct NearsideHomeView: View {
    @ObservedObject var appState: AppState

    @State private var isShowingPairSheet: Bool = false
    @State private var isShowingSettingsSheet: Bool = false
    @State private var isShowingFilePicker: Bool = false
    @State private var isShowingPhotoPicker: Bool = false
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var selectedPeerForSend: NearsideDevice?

    @MainActor
    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        NavigationStack {
            List {
                // Clipboard Toast Banner
                if let toast = appState.clipboardToastMessage {
                    Section {
                        HStack(spacing: 10) {
                            Image(systemName: "doc.on.clipboard.fill")
                                .foregroundStyle(Color.accentColor)
                            Text(toast)
                                .font(.subheadline)
                                .bold()
                        }
                        .padding(.vertical, 2)
                    }
                }

                // Control Center Style Hero Card
                Section {
                    ControlCenterHeroCard(
                        isReceivingActive: $appState.isReceivingActive,
                        deviceName: appState.localDeviceName
                    )
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                .listRowBackground(Color.clear)

                // In-Flight Velocity Transfer Card
                if let transfer = appState.activeTransfer {
                    Section {
                        ActiveTransferVelocityCard(
                            transfer: transfer,
                            onCancel: {
                                appState.cancelTransfer(id: transfer.id)
                            }
                        )
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                    .listRowBackground(Color.clear)
                }

                // Direct Media Dispatch Bar
                Section {
                    DirectActionsBar(
                        onPickFiles: {
                            selectedPeerForSend = appState.pairedDevices.first
                            isShowingFilePicker = true
                        },
                        onPickPhotos: {
                            selectedPeerForSend = appState.pairedDevices.first
                            isShowingPhotoPicker = true
                        },
                        onShowPairing: {
                            isShowingPairSheet = true
                        }
                    )
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)

                // Available Peers
                Section(header: Text("Available Peers").font(.caption).bold()) {
                    if appState.pairedDevices.isEmpty {
                        Text("No paired peers. Tap 'Pair' to connect a nearby Mac or phone.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(appState.pairedDevices) { device in
                            PeerDeviceRow(
                                device: device,
                                onSendFiles: {
                                    selectedPeerForSend = device
                                    isShowingFilePicker = true
                                },
                                onSendPhotos: {
                                    selectedPeerForSend = device
                                    isShowingPhotoPicker = true
                                },
                                onBeamClipboard: {
                                    appState.sendClipboard(to: device)
                                },
                                onUnpair: {
                                    appState.unpairDevice(id: device.id)
                                }
                            )
                        }
                    }
                }

                // Discovered Peers
                if !appState.discoveredDevices.isEmpty {
                    Section(header: Text("Nearby on Local Network").font(.caption).bold()) {
                        ForEach(appState.discoveredDevices) { device in
                            HStack {
                                Image(systemName: iconForPlatform(device.platform))
                                    .foregroundStyle(colorForPlatform(device.platform))
                                    .frame(width: 28)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name)
                                        .font(.subheadline)
                                        .bold()
                                    Text(device.ipAddress ?? "Discovered")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Text("Available")
                                    .font(.caption)
                                    .foregroundStyle(.green)
                            }
                        }
                    }
                }

                // Recent Transfers
                if !appState.transferHistory.isEmpty {
                    Section(header:
                        HStack {
                            Text("Recent Transfers").font(.caption).bold()
                            Spacer()
                            Button("Clear") {
                                appState.clearHistory()
                            }
                            .font(.caption)
                        }
                    ) {
                        ForEach(appState.transferHistory.prefix(5)) { record in
                            TransferHistoryRow(record: record)
                        }
                    }
                }
            }
            .navigationTitle("Nearside")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        isShowingSettingsSheet = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }

                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        isShowingPairSheet = true
                    } label: {
                        Image(systemName: "qrcode.viewfinder")
                    }
                    .accessibilityLabel("Scan pairing QR code")
                    .accessibilityIdentifier("scanPairingQR")

                    Button {
                        isShowingPairSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .bold()
                    }
                }
            }
            .fileImporter(
                isPresented: $isShowingFilePicker,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                guard let device = selectedPeerForSend else { return }
                switch result {
                case .success(let urls):
                    appState.sendFiles(urls: urls, to: device)
                case .failure:
                    break
                }
            }
            .photosPicker(
                isPresented: $isShowingPhotoPicker,
                selection: $selectedPhotoItems,
                matching: .any(of: [.images, .videos])
            )
            .onChange(of: selectedPhotoItems) { _, items in
                guard !items.isEmpty, let device = selectedPeerForSend else { return }
                Task {
                    var stagedURLs: [URL] = []
                    for item in items {
                        if let data = try? await item.loadTransferable(type: Data.self) {
                            let tempURL = FileManager.default.temporaryDirectory
                                .appendingPathComponent("photo_\(UUID().uuidString.prefix(8)).jpg")
                            try? data.write(to: tempURL)
                            stagedURLs.append(tempURL)
                        }
                    }
                    if !stagedURLs.isEmpty {
                        await MainActor.run {
                            appState.sendFiles(urls: stagedURLs, to: device)
                            selectedPhotoItems.removeAll()
                        }
                    }
                }
            }
            .sheet(isPresented: $isShowingPairSheet) {
                QRPairingScannerView(appState: appState)
            }
            .sheet(isPresented: $isShowingSettingsSheet) {
                NearsideSettingsView(appState: appState)
            }
        }
    }
}

// MARK: - Control Center Hero Card
struct ControlCenterHeroCard: View {
    @Binding var isReceivingActive: Bool
    let deviceName: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .fill(isReceivingActive ? Color.green.opacity(0.18) : Color.secondary.opacity(0.15))
                        .frame(width: 44, height: 44)

                    Image(systemName: isReceivingActive ? "antenna.radiowaves.left.and.right" : "power")
                        .font(.title3)
                        .foregroundStyle(isReceivingActive ? Color.green : Color.secondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(isReceivingActive ? "Receiving Ready" : "Dormant (Off)")
                        .font(.headline)
                        .bold()
                    Text(isReceivingActive ? "Port 41433 • Broadcasting mDNS" : "Zero battery • Sockets closed")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Toggle("", isOn: $isReceivingActive)
                    .labelsHidden()
            }

            Text(isReceivingActive ?
                 "Nearside is receptive to inbound files and clipboard beaming from trusted peers on this network." :
                 "Receiving is turned off to save battery and memory. Outbound sending remains available anytime.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(isReceivingActive ? Color.green.opacity(0.08) : Color(.secondarySystemBackground))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(isReceivingActive ? Color.green.opacity(0.25) : Color.clear, lineWidth: 1)
                )
        )
    }
}

// MARK: - Active Transfer Velocity Card
struct ActiveTransferVelocityCard: View {
    let transfer: TransferRecord
    let onCancel: () -> Void

    var body: some View {
        let isIncoming = transfer.direction == .incoming
        let speedText: String = {
            guard transfer.transferSpeedBytesPerSec > 0 else { return "" }
            let mbps = transfer.transferSpeedBytesPerSec / (1024.0 * 1024.0)
            return mbps >= 1.0 ? String(format: "%.1f MB/s", mbps) : String(format: "%.0f KB/s", transfer.transferSpeedBytesPerSec / 1024.0)
        }()

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(isIncoming ? Color.green.opacity(0.18) : Color.accentColor.opacity(0.18))
                        .frame(width: 34, height: 34)

                    Image(systemName: isIncoming ? "arrow.down" : "arrow.up")
                        .font(.subheadline)
                        .bold()
                        .foregroundStyle(isIncoming ? Color.green : Color.accentColor)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(isIncoming ? "Receiving from \(transfer.deviceName)..." : "Sending to \(transfer.deviceName)...")
                        .font(.subheadline)
                        .bold()
                    Text("\(transfer.filename) (\(formatBytes(transfer.totalSizeBytes)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text("\(Int(transfer.progress * 100))%")
                    .font(.subheadline)
                    .bold()
                    .monospacedDigit()
                    .foregroundStyle(Color.accentColor)
            }

            ProgressView(value: transfer.progress)
                .tint(Color.accentColor)

            HStack {
                if !speedText.isEmpty {
                    Label(speedText, systemImage: "speedometer")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: onCancel) {
                    Label("Cancel", systemImage: "xmark")
                        .font(.caption)
                        .bold()
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.red.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.red)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Direct Actions Bar
struct DirectActionsBar: View {
    let onPickFiles: () -> Void
    let onPickPhotos: () -> Void
    let onShowPairing: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onPickFiles) {
                Label("Files", systemImage: "folder")
                    .font(.subheadline)
                    .bold()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)

            Button(action: onPickPhotos) {
                Label("Photos", systemImage: "photo.on.rectangle")
                    .font(.subheadline)
                    .bold()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)

            Button(action: onShowPairing) {
                Label("Pair", systemImage: "qrcode")
                    .font(.subheadline)
                    .bold()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - Peer Device Row
struct PeerDeviceRow: View {
    let device: NearsideDevice
    let onSendFiles: () -> Void
    let onSendPhotos: () -> Void
    let onBeamClipboard: () -> Void
    let onUnpair: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(colorForPlatform(device.platform).opacity(0.15))
                        .frame(width: 38, height: 38)

                    Image(systemName: iconForPlatform(device.platform))
                        .font(.body)
                        .foregroundStyle(colorForPlatform(device.platform))
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(device.name)
                            .font(.body)
                            .bold()

                        Text(device.platform.displayName)
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(colorForPlatform(device.platform).opacity(0.15), in: Capsule())
                            .foregroundStyle(colorForPlatform(device.platform))
                    }

                    Text("\(device.shortFingerprint) • \(device.ipAddress ?? "Direct")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: onUnpair) {
                    Image(systemName: "trash")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
            }

            HStack(spacing: 8) {
                Button(action: onSendFiles) {
                    Label("Send File", systemImage: "folder")
                        .font(.caption)
                        .bold()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.borderless)

                Button(action: onSendPhotos) {
                    Label("Photos", systemImage: "photo")
                        .font(.caption)
                        .bold()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.borderless)

                Button(action: onBeamClipboard) {
                    Label("Beam", systemImage: "doc.on.clipboard")
                        .font(.caption)
                        .bold()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Transfer History Row
struct TransferHistoryRow: View {
    let record: TransferRecord

    var body: some View {
        HStack {
            let iconName: String = {
                if record.status == .cancelled { return "xmark.circle.fill" }
                if record.payloadType == .url { return "link.circle.fill" }
                if record.payloadType == .text { return "doc.on.clipboard.fill" }
                return record.direction == .incoming ? "arrow.down.circle.fill" : "arrow.up.circle.fill"
            }()

            let statusColor: Color = {
                if record.status == .cancelled { return .orange }
                if record.status == .completed { return .green }
                return .red
            }()

            Image(systemName: iconName)
                .foregroundStyle(statusColor)

            VStack(alignment: .leading, spacing: 2) {
                Text(record.filename)
                    .font(.subheadline)
                    .bold()
                Text("\(record.deviceName) • \(record.formattedSize)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(record.status == .completed ? "Done" : (record.status == .cancelled ? "Cancelled" : "Failed"))
                .font(.caption2)
                .bold()
                .foregroundStyle(statusColor)
        }
    }
}

// MARK: - Helpers
func iconForPlatform(_ platform: DevicePlatform) -> String {
    switch platform {
    case .macOS: return "laptopcomputer"
    case .iOS: return "iphone"
    case .android: return "phone.fill"
    case .windows: return "desktopcomputer"
    case .linux: return "terminal.fill"
    }
}

func colorForPlatform(_ platform: DevicePlatform) -> Color {
    switch platform {
    case .macOS: return Color(red: 0.1, green: 0.5, blue: 0.95)
    case .iOS: return Color(red: 0.6, green: 0.35, blue: 0.95)
    case .android: return Color(red: 0.05, green: 0.72, blue: 0.5)
    case .windows: return Color(red: 0.0, green: 0.55, blue: 0.9)
    case .linux: return Color(red: 0.92, green: 0.45, blue: 0.1)
    }
}

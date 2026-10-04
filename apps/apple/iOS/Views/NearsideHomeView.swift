import SwiftUI

public struct NearsideHomeView: View {
    @ObservedObject var appState: AppState

    @State private var isShowingPairSheet: Bool = false
    @State private var isShowingSettingsSheet: Bool = false
    @State private var isShowingFilePicker: Bool = false
    @State private var selectedPeerForSend: NearsideDevice?

    @MainActor
    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        NavigationStack {
            List {
                // Status Section
                Section {
                    HStack(spacing: 16) {
                        Circle()
                            .fill(appState.isReceivingActive ? Color.green : Color.orange)
                            .frame(width: 14, height: 14)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(appState.isReceivingActive ? "Ready to Receive" : "Receiving Paused")
                                .font(.headline)
                            Text(appState.localDeviceName)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Toggle("", isOn: $appState.isReceivingActive)
                            .labelsHidden()
                    }
                    .padding(.vertical, 4)
                }

                // Active Transfer Banner
                if let transfer = appState.activeTransfer {
                    Section(header: Text("Active Transfer")) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "arrow.up.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                                Text(transfer.filename)
                                    .font(.headline)
                                Spacer()
                                Text("\(Int(transfer.progress * 100))%")
                                    .font(.subheadline)
                                    .bold()
                            }

                            ProgressView(value: transfer.progress)
                                .tint(Color.accentColor)

                            HStack {
                                Text("To: \(transfer.deviceName)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(formatBytes(transfer.totalSizeBytes))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                // Paired Devices
                Section(header: Text("Paired Devices")) {
                    if appState.pairedDevices.isEmpty {
                        Text("No paired devices. Tap '+' above to pair a nearby Mac or phone.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .padding(.vertical, 8)
                    } else {
                        ForEach(appState.pairedDevices) { device in
                            HStack(spacing: 12) {
                                Image(systemName: iconForPlatform(device.platform))
                                    .font(.title3)
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 32)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(device.name)
                                            .font(.body)
                                            .bold()
                                        if device.reachability == .online {
                                            Circle()
                                                .fill(Color.green)
                                                .frame(width: 8, height: 8)
                                        }
                                    }
                                    Text(device.fingerprint)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Button {
                                    sendSimulatedFile(to: device)
                                } label: {
                                    Text("Send")
                                        .font(.subheadline)
                                        .bold()
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 6)
                                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                                }
                                .buttonStyle(.borderless)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                // Nearby Discovered Peers
                Section(header: Text("Nearby on Local Network")) {
                    if appState.discoveredDevices.isEmpty {
                        Text("Searching for nearby Nearside devices on Wi-Fi...")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.discoveredDevices) { device in
                            HStack {
                                Image(systemName: iconForPlatform(device.platform))
                                    .foregroundStyle(.secondary)
                                    .frame(width: 24)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name)
                                        .font(.subheadline)
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
                    Section(header: Text("Recent Transfers")) {
                        ForEach(appState.transferHistory.prefix(5)) { record in
                            HStack {
                                Image(systemName: record.direction == .incoming ? "arrow.down.circle" : "arrow.up.circle")
                                    .foregroundStyle(record.status == .completed ? Color.green : Color.red)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(record.filename)
                                        .font(.subheadline)
                                    Text("\(record.deviceName) • \(formatBytes(record.totalSizeBytes))")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }

                                Spacer()

                                Text(record.status == .completed ? "Done" : "Failed")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
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

                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        isShowingPairSheet = true
                    } label: {
                        Image(systemName: "plus")
                            .bold()
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

    private func sendSimulatedFile(to device: NearsideDevice) {
        appState.simulateOutgoingTransfer(
            to: device,
            filenames: ["Shared_Photo.jpg"],
            totalBytes: 4 * 1024 * 1024
        )
    }

    private func iconForPlatform(_ platform: DevicePlatform) -> String {
        switch platform {
        case .macOS: return "laptopcomputer"
        case .iOS: return "iphone"
        case .android: return "phone.fill"
        case .windows: return "desktopcomputer"
        case .linux: return "terminal.fill"
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

import SwiftUI

public struct NearsideSettingsView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("This Device")) {
                    HStack {
                        Text("Device Name")
                        Spacer()
                        Text(appState.localDeviceName)
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Device Fingerprint")
                            .font(.subheadline)
                        Text(appState.localFingerprint)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    .padding(.vertical, 2)
                }

                Section(header: Text("Receiving Preferences")) {
                    Toggle("Active Receiver", isOn: $appState.isReceivingActive)
                    Toggle("Auto-Accept from Paired", isOn: $appState.autoAcceptFromPaired)

                    HStack {
                        Text("Storage Destination")
                        Spacer()
                        Text("Sandbox Documents")
                            .foregroundStyle(.secondary)
                    }
                }

                Section(header: Text("Trusted Peers (\(appState.pairedDevices.count))")) {
                    if appState.pairedDevices.isEmpty {
                        Text("No paired devices enrolled.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(appState.pairedDevices) { device in
                            HStack {
                                Image(systemName: iconForPlatform(device.platform))
                                    .foregroundStyle(Color.accentColor)
                                    .frame(width: 24)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name)
                                        .font(.body)
                                    Text(device.fingerprint)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                let device = appState.pairedDevices[index]
                                appState.unpairDevice(id: device.id)
                            }
                        }
                    }
                }

                Section(footer: Text("Nearside is open-source, local-first, and peer-to-peer. Zero telemetry, zero cloud intermediary servers.")) {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0 (Milestone 5)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
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
}

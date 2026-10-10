import SwiftUI

public struct NearsideSettingsView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var pendingUnpair: NearsideDevice?
    @State private var unpairError: String?

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
                    Toggle("Active Receiver", isOn: Binding(
                        get: { appState.isReceivingActive },
                        set: { value in
                            if value != appState.isReceivingActive { appState.toggleReceiving() }
                        }
                    ))
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
                            .swipeActions {
                                Button("Unpair", role: .destructive) { pendingUnpair = device }
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
            .confirmationDialog("Remove this device's trust?", isPresented: Binding(
                get: { pendingUnpair != nil },
                set: { if !$0 { pendingUnpair = nil } }
            ), titleVisibility: .visible) {
                if let device = pendingUnpair {
                    Button("Unpair \(device.name)", role: .destructive) {
                        if case .failure(let error) = appState.unpairDevice(id: device.id) {
                            unpairError = error.localizedDescription
                        }
                        pendingUnpair = nil
                    }
                }
                Button("Cancel", role: .cancel) { pendingUnpair = nil }
            } message: {
                if let device = pendingUnpair {
                    Text("Only \(device.name) (\(device.shortFingerprint)) will be removed. Pair again to transfer content.")
                }
            }
            .alert("Unable to Unpair", isPresented: Binding(
                get: { unpairError != nil },
                set: { if !$0 { unpairError = nil } }
            )) {
                Button("OK") { unpairError = nil }
            } message: {
                Text(unpairError ?? "")
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

import SwiftUI
import AppKit

@MainActor
public struct PreferencesView: View {
    @ObservedObject var appState: AppState
    @State private var selectedTab: Int = 0
    @State private var showingPairSheet: Bool = false
    @State private var pairingTarget: NearsideDevice?
    @State private var unpairCandidate: NearsideDevice?

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(0)

            devicesTab
                .tabItem {
                    Label("Paired Devices", systemImage: "laptopcomputer.and.iphone")
                }
                .tag(1)

            networkTab
                .tabItem {
                    Label("Network", systemImage: "network")
                }
                .tag(2)
        }
        .padding(20)
        .frame(width: 520, height: 420)
        .sheet(isPresented: $showingPairSheet) {
            MacPairingView(appState: appState, target: pairingTarget)
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

    // MARK: - General Tab
    private var generalTab: some View {
        Form {
            Section(header: Text("Device Identity").font(.headline)) {
                TextField("Computer Name", text: $appState.localDeviceName)
                    .textFieldStyle(.roundedBorder)

                HStack {
                    Text("Identity Fingerprint:")
                        .foregroundColor(.secondary)
                    Text(appState.localFingerprint)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            Divider()
                .padding(.vertical, 8)

            Section(header: Text("Receiving").font(.headline)) {
                Toggle("Accept inbound transfers", isOn: Binding(
                    get: { appState.isReceivingActive },
                    set: { value in
                        if value != appState.isReceivingActive { appState.toggleReceiving() }
                    }
                ))

                Toggle("Automatically accept files from paired devices", isOn: $appState.autoAcceptFromPaired)

                HStack {
                    Text("Save received files to:")
                    Spacer()
                    Text(appState.downloadsFolderURL.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundColor(.secondary)
                        .font(.caption)

                    Button("Choose...") {
                        selectDownloadsFolder()
                    }
                }
            }
        }
    }

    // MARK: - Paired Devices Tab
    private var devicesTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Trusted Devices")
                    .font(.headline)
                Spacer()
                Button(action: {
                    pairingTarget = nil
                    showingPairSheet = true
                }) {
                    Label("Pair New Device", systemImage: "plus")
                }
            }

            if let message = appState.clipboardToastMessage {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if appState.pairedDevices.isEmpty && appState.discoveredDevices.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "shield.slash")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary)
                    Text("No paired devices enrolled")
                        .foregroundColor(.secondary)
                    Text("Click 'Pair New Device' to establish a trust relationship.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    let unpariedDiscovered = appState.availableNearbyDevices
                    if !unpariedDiscovered.isEmpty {
                        Section(header: Text("Discovered Nearby").font(.caption).foregroundColor(.secondary)) {
                            ForEach(unpariedDiscovered) { device in
                                HStack {
                                    Image(systemName: device.platform.systemSymbolName)
                                        .font(.system(size: 16))
                                        .foregroundColor(.accentColor)
                                        .frame(width: 24)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(device.name)
                                            .font(.system(size: 13, weight: .medium))
                                        Text(device.ipAddress ?? "Wi-Fi Peer")
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    Button("Pair") {
                                        pairingTarget = device
                                        showingPairSheet = true
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .controlSize(.small)
                                }
                                .padding(.vertical, 2)
                            }
                        }
                    }

                    if !appState.pairedDevices.isEmpty {
                        Section(header: Text("Paired Devices").font(.caption).foregroundColor(.secondary)) {
                            ForEach(appState.pairedDevices) { device in
                                HStack {
                                    Image(systemName: device.platform.systemSymbolName)
                                        .font(.system(size: 18))
                                        .foregroundColor(.accentColor)
                                        .frame(width: 28)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(device.name)
                                            .font(.system(size: 13, weight: .medium))
                                        Text(device.fingerprint)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundColor(.secondary)
                                    }

                                    Spacer()

                                    Button(action: {
                                        unpairCandidate = device
                                    }) {
                                        Text("Unpair")
                                            .font(.caption)
                                            .foregroundColor(.red)
                                    }
                                    .buttonStyle(.plain)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Network Tab
    private var networkTab: some View {
        Form {
            Section(header: Text("Transport & Discovery").font(.headline)) {
                LabeledContent("Discovery Service") {
                    Text("_nearside._tcp.local. (mDNS)")
                        .font(.system(.body, design: .monospaced))
                }

                LabeledContent("TCP Listener Port") {
                    Text("41433 (Dynamic)")
                        .font(.system(.body, design: .monospaced))
                }

                LabeledContent("Protocol Version") {
                    Text("Nearside v1 (P-256 / AES-GCM / 64 KiB chunks)")
                }

                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(appState.isReceivingActive ? Color.green : Color.orange)
                            .frame(width: 8, height: 8)
                        Text(appState.isReceivingActive ? "Listening for peers" : "Paused")
                    }
                }
            }
        }
    }

    private func selectDownloadsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        panel.title = "Choose Destination Folder"

        if panel.runModal() == .OK, let selectedURL = panel.url {
            appState.downloadsFolderURL = selectedURL
        }
    }
}

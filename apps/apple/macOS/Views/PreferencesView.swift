import SwiftUI
import AppKit

@MainActor
public struct PreferencesView: View {
    @ObservedObject var appState: AppState
    @State private var selectedTab: Int = 1
    @State private var showingPairSheet: Bool = false
    @State private var shortCodeInput: String = ""
    @State private var pairMode: Int = 0 // 0 = QR, 1 = Short Code

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 12) {
            // Pure liquid glass tab picker (zero white shadow)
            HStack {
                Spacer()
                glassPicker
                Spacer()
            }
            .padding(.top, 4)

            Group {
                switch selectedTab {
                case 0:
                    generalTab
                case 1:
                    devicesTab
                case 2:
                    networkTab
                default:
                    devicesTab
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: 420)
        .sheet(isPresented: $showingPairSheet) {
            pairingSheet
        }
    }

    // MARK: - Liquid Glass Segmented Picker
    private var glassPicker: some View {
        HStack(spacing: 0) {
            segmentButton("General", tag: 0)
            segmentButton("Paired Devices", tag: 1)
            segmentButton("Network", tag: 2)
        }
        .padding(2)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.08))
                .overlay(
                    Capsule()
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                )
        )
    }

    private func segmentButton(_ title: String, tag: Int) -> some View {
        let isSelected = selectedTab == tag
        return Button(action: {
            selectedTab = tag
        }) {
            Text(title)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .foregroundColor(isSelected ? .white : Color.white.opacity(0.6))
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .background(
                    Group {
                        if isSelected {
                            Capsule()
                                .fill(Color.white.opacity(0.16))
                                .overlay(
                                    Capsule()
                                        .stroke(Color.white.opacity(0.20), lineWidth: 0.5)
                                )
                        } else {
                            Color.clear
                        }
                    }
                )
        }
        .buttonStyle(.plain)
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
                Toggle("Accept inbound transfers", isOn: $appState.isReceivingActive)

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
                    showingPairSheet = true
                }) {
                    Label("Pair New Device", systemImage: "plus")
                }
            }

            if appState.pairedDevices.isEmpty {
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
                                appState.unpairDevice(id: device.id)
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

    // MARK: - Pairing Sheet
    private var pairingSheet: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Pair New Device")
                    .font(.headline)
                Spacer()
                Button("Done") {
                    showingPairSheet = false
                }
            }

            // Liquid glass pill switcher for pairing sheet as well
            HStack(spacing: 0) {
                pairingSegmentButton("QR Code", tag: 0)
                pairingSegmentButton("Short Code", tag: 1)
            }
            .padding(2)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        Capsule()
                            .stroke(Color.white.opacity(0.12), lineWidth: 0.5)
                    )
            )

            if pairMode == 0 {
                VStack(spacing: 12) {
                    Text("Scan this QR code with the Nearside app on your Android device:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.primary.opacity(0.2), lineWidth: 1)
                            .frame(width: 180, height: 180)
                            .background(Color.white)

                        VStack(spacing: 8) {
                            Image(systemName: "qrcode")
                                .font(.system(size: 100))
                                .foregroundColor(.black)
                            Text("nearside://pair")
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundColor(.gray)
                        }
                    }

                    Text("Fingerprint: \(appState.localFingerprint.prefix(16))...")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 14) {
                    Text("Enter the 8-digit verification code shown on the peer device:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextField("12345678", text: $shortCodeInput)
                        .font(.system(size: 24, weight: .bold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .frame(width: 200)
                        .textFieldStyle(.roundedBorder)

                    Button("Confirm Pairing") {
                        if shortCodeInput.count >= 6 {
                            let newDev = NearsideDevice(
                                name: "Paired Peer (\(shortCodeInput.prefix(4)))",
                                platform: .android,
                                fingerprint: "ns1_mock_\(shortCodeInput)"
                            )
                            appState.pairedDevices.append(newDev)
                            showingPairSheet = false
                            shortCodeInput = ""
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 16)
            }

            Spacer()
        }
        .padding(24)
        .frame(width: 380, height: 340)
    }

    private func pairingSegmentButton(_ title: String, tag: Int) -> some View {
        let isSelected = pairMode == tag
        return Button(action: {
            pairMode = tag
        }) {
            Text(title)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .foregroundColor(isSelected ? .white : Color.white.opacity(0.6))
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
                .background(
                    Group {
                        if isSelected {
                            Capsule()
                                .fill(Color.white.opacity(0.16))
                                .overlay(
                                    Capsule()
                                        .stroke(Color.white.opacity(0.20), lineWidth: 0.5)
                                )
                        } else {
                            Color.clear
                        }
                    }
                )
        }
        .buttonStyle(.plain)
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

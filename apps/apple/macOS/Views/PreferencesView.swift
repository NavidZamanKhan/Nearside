import SwiftUI
import AppKit
import CryptoKit
import CoreImage

@MainActor
public struct PreferencesView: View {
    @ObservedObject var appState: AppState
    @State private var selectedTab: Int = 0
    @State private var showingPairSheet: Bool = false
    @State private var shortCodeInput: String = ""
    @State private var pairMode: Int = 0 // 0 = QR, 1 = Short Code

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
            pairingSheet
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
                    let unpariedDiscovered = appState.discoveredDevices.filter { disc in
                        !appState.pairedDevices.contains(where: { $0.id == disc.id })
                    }
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
                                        appState.pairDiscoveredDevice(device)
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

    @State private var qrPayload: QRPairingPayload?
    @State private var localPakeCode: String = ""

    private var currentQRUri: String {
        return qrPayload?.toURI() ?? "nearside://pair?v=1"
    }

    private func generateQRCode(from string: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 6, y: 6))
        let rep = NSCIImageRep(ciImage: scaled)
        let img = NSImage(size: rep.size)
        img.addRepresentation(rep)
        return img
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

            Picker("Pairing Mode", selection: $pairMode) {
                Text("QR Code").tag(0)
                Text("Short Code").tag(1)
            }
            .pickerStyle(.segmented)

            if pairMode == 0 {
                VStack(spacing: 10) {
                    Text("Scan this QR code with Nearside on your Android device:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    if let qrImage = generateQRCode(from: currentQRUri) {
                        Image(nsImage: qrImage)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 150, height: 150)
                            .padding(6)
                            .background(Color.white)
                            .cornerRadius(8)
                    }

                    Text("Session ID: \(qrPayload?.sessionId.prefix(8) ?? "")")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                VStack(spacing: 14) {
                    Text("Your Pairing Short Code:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text(localPakeCode)
                        .font(.system(size: 28, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.primary.opacity(0.06))
                        .cornerRadius(8)

                    Text("Or enter code from peer:")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    TextField("12345678", text: $shortCodeInput)
                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .frame(width: 180)
                        .textFieldStyle(.roundedBorder)

                    Button("Confirm Pairing") {
                        let input = shortCodeInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        if let uriPayload = QRPairingPayload.fromURI(input) {
                            appState.pairWithQrPayload(uriPayload)
                            showingPairSheet = false
                            shortCodeInput = ""
                        } else if input.contains(".") {
                            let parts = input.split(separator: ":")
                            let host = String(parts[0])
                            let port = parts.count > 1 ? (UInt16(parts[1]) ?? 41433) : 41433
                            appState.pairWithPeerAddress(host: host, port: port, confirmationCode: "")
                            showingPairSheet = false
                            shortCodeInput = ""
                        } else if let disc = appState.discoveredDevices.first(where: { d in !appState.pairedDevices.contains(where: { p in p.id == d.id }) }) ?? appState.discoveredDevices.first {
                            appState.pairDiscoveredDevice(disc)
                            showingPairSheet = false
                            shortCodeInput = ""
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(.vertical, 10)
            }

            Spacer()
        }
        .padding(20)
        .frame(width: 380, height: 350)
        .onAppear {
            let payload = QRPairingPayload(hostIdentity: appState.localFingerprint, hostName: appState.localDeviceName)
            QRPairingSessions.shared.register(payload)
            self.qrPayload = payload
            self.localPakeCode = String(format: "%04d %04d", Int.random(in: 1000...9999), Int.random(in: 1000...9999))
        }
        .onDisappear {
            if let payload = qrPayload { QRPairingSessions.shared.unregister(payload.sessionId) }
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

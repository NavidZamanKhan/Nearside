import SwiftUI
import AppKit

public struct VisualEffectBackground: NSViewRepresentable {
    public init() {}

    public func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    public func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

@MainActor
public struct PreferencesView: View {
    @ObservedObject var appState: AppState
    @State private var selectedTab: Int = 1 // Default to Paired Devices tab as in screenshot
    @State private var showingPairSheet: Bool = false
    @State private var shortCodeInput: String = ""
    @State private var pairMode: Int = 0 // 0 = QR, 1 = Short Code
    @State private var hoveredTab: Int? = nil

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Top Window Drag Region and Custom Liquid Glass Tab Switcher
            VStack(spacing: 12) {
                liquidGlassTabBar
                    .padding(.top, 14)
            }
            .padding(.bottom, 12)

            Divider()
                .opacity(0.12)

            // Tab Content
            ScrollView(.vertical, showsIndicators: false) {
                Group {
                    switch selectedTab {
                    case 0:
                        generalContent
                    case 1:
                        devicesContent
                    case 2:
                        networkContent
                    default:
                        devicesContent
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 560, height: 460)
        .background(VisualEffectBackground().ignoresSafeArea())
        .sheet(isPresented: $showingPairSheet) {
            pairingSheet
        }
    }

    // MARK: - Liquid Glass Tab Bar (Zero White Shadow)
    private var liquidGlassTabBar: some View {
        HStack(spacing: 3) {
            tabItem(title: "General", icon: "gearshape", tag: 0)
            tabItem(title: "Paired Devices", icon: "laptopcomputer.and.iphone", tag: 1)
            tabItem(title: "Network", icon: "network", tag: 2)
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.black.opacity(0.4))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.8)
                )
        )
    }

    private func tabItem(title: String, icon: String, tag: Int) -> some View {
        let isSelected = selectedTab == tag
        let isHovered = hoveredTab == tag

        return Button(action: {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                selectedTab = tag
            }
        }) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                Text(title)
                    .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
            }
            .foregroundColor(
                isSelected
                    ? Color.white
                    : (isHovered ? Color.white.opacity(0.9) : Color.white.opacity(0.6))
            )
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                Group {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.20),
                                        Color.white.opacity(0.10)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .stroke(Color.white.opacity(0.22), lineWidth: 0.6)
                            )
                    } else if isHovered {
                        RoundedRectangle(cornerRadius: 9, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                    } else {
                        Color.clear
                    }
                }
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hoveredTab = inside ? tag : nil
        }
    }

    // MARK: - General Content
    private var generalContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            glassCard(title: "Device Identity") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Computer Name:")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(width: 120, alignment: .leading)
                        TextField("Computer Name", text: $appState.localDeviceName)
                            .textFieldStyle(.roundedBorder)
                    }

                    HStack {
                        Text("Fingerprint:")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                            .frame(width: 120, alignment: .leading)
                        Text(appState.localFingerprint)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.primary)
                            .textSelection(.enabled)
                    }
                }
            }

            glassCard(title: "Receiving Configuration") {
                VStack(alignment: .leading, spacing: 12) {
                    Toggle("Accept inbound transfers", isOn: $appState.isReceivingActive)
                        .font(.system(size: 12))

                    Toggle("Automatically accept files from paired devices", isOn: $appState.autoAcceptFromPaired)
                        .font(.system(size: 12))

                    Divider().opacity(0.15)

                    HStack {
                        Text("Save transfers to:")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text(appState.downloadsFolderURL.path)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundColor(.secondary)

                        Button("Choose...") {
                            selectDownloadsFolder()
                        }
                        .font(.system(size: 11))
                    }
                }
            }
        }
    }

    // MARK: - Paired Devices Content
    private var devicesContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Trusted Devices")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button(action: {
                    showingPairSheet = true
                }) {
                    HStack(spacing: 5) {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                        Text("Pair New Device")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.18), lineWidth: 0.6)
                    )
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }

            if appState.pairedDevices.isEmpty {
                VStack(spacing: 10) {
                    Spacer().frame(height: 30)
                    Image(systemName: "shield.slash")
                        .font(.system(size: 32))
                        .foregroundColor(.secondary.opacity(0.6))
                    Text("No paired devices enrolled")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(.secondary)
                    Text("Click 'Pair New Device' to establish a trust relationship.")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary.opacity(0.7))
                    Spacer().frame(height: 30)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .background(Color.white.opacity(0.03))
                .cornerRadius(12)
            } else {
                VStack(spacing: 8) {
                    ForEach(appState.pairedDevices) { device in
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color.blue.opacity(0.18))
                                    .frame(width: 34, height: 34)
                                Image(systemName: device.platform.systemSymbolName)
                                    .font(.system(size: 15))
                                    .foregroundColor(.blue)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name)
                                    .font(.system(size: 12, weight: .semibold))
                                Text(device.fingerprint)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }

                            Spacer()

                            Button(action: {
                                appState.unpairDevice(id: device.id)
                            }) {
                                Text("Unpair")
                                    .font(.system(size: 11))
                                    .foregroundColor(.red.opacity(0.85))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.red.opacity(0.1))
                                    .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(10)
                        .background(Color.white.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(Color.white.opacity(0.08), lineWidth: 0.6)
                        )
                        .cornerRadius(10)
                    }
                }
            }
        }
    }

    // MARK: - Network Content
    private var networkContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            glassCard(title: "Transport & Discovery") {
                VStack(spacing: 10) {
                    networkRow(label: "Service Name", value: "_nearside._tcp.local.")
                    networkRow(label: "Listener Port", value: "41433 (TCP)")
                    networkRow(label: "Protocol Spec", value: "Nearside v1 (P-256 / AES-GCM)")

                    Divider().opacity(0.15)

                    HStack {
                        Text("Discovery State")
                            .font(.system(size: 12))
                            .foregroundColor(.secondary)
                        Spacer()
                        HStack(spacing: 6) {
                            Circle()
                                .fill(appState.isReceivingActive ? Color.green : Color.orange)
                                .frame(width: 7, height: 7)
                            Text(appState.isReceivingActive ? "Broadcasting & Listening" : "Paused")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(appState.isReceivingActive ? .green : .orange)
                        }
                    }
                }
            }
        }
    }

    private func networkRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.primary)
        }
    }

    private func glassCard<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(14)
            .background(Color.white.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 0.6)
            )
            .cornerRadius(12)
        }
    }

    // MARK: - Pairing Sheet
    private var pairingSheet: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Pair New Device")
                    .font(.system(size: 14, weight: .bold))
                Spacer()
                Button("Done") {
                    showingPairSheet = false
                }
                .font(.system(size: 12))
            }

            // Clean custom 2-pill switcher without white shadow
            HStack(spacing: 2) {
                pairModeButton(title: "QR Code", tag: 0)
                pairModeButton(title: "Short Code", tag: 1)
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.black.opacity(0.4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 0.6)
                    )
            )

            if pairMode == 0 {
                VStack(spacing: 12) {
                    Text("Scan this QR code with the Nearside app on your Android device:")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)

                    ZStack {
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white)
                            .frame(width: 170, height: 170)

                        VStack(spacing: 6) {
                            Image(systemName: "qrcode")
                                .font(.system(size: 96))
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
                        .font(.system(size: 11))
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
        .frame(width: 380, height: 350)
        .background(VisualEffectBackground().ignoresSafeArea())
    }

    private func pairModeButton(title: String, tag: Int) -> some View {
        let isSelected = pairMode == tag
        return Button(action: {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                pairMode = tag
            }
        }) {
            Text(title)
                .font(.system(size: 11, weight: isSelected ? .semibold : .medium))
                .foregroundColor(isSelected ? .white : Color.white.opacity(0.6))
                .padding(.horizontal, 16)
                .padding(.vertical, 5)
                .background(
                    Group {
                        if isSelected {
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.white.opacity(0.18))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .stroke(Color.white.opacity(0.2), lineWidth: 0.5)
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

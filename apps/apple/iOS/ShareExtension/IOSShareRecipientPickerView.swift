import SwiftUI

public struct IOSShareRecipientPickerView: View {
    public let stagedFiles: [URL]
    public let devices: [NearsideDevice]
    public let onSelectRecipient: (NearsideDevice) -> Void
    public let onCancel: () -> Void

    @State private var activeTransferringDevice: NearsideDevice?
    @State private var transferProgress: Double = 0.0

    public init(
        stagedFiles: [URL],
        devices: [NearsideDevice],
        onSelectRecipient: @escaping (NearsideDevice) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.stagedFiles = stagedFiles
        self.devices = devices
        self.onSelectRecipient = onSelectRecipient
        self.onCancel = onCancel
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Header summary of items
                HStack(spacing: 12) {
                    Image(systemName: "doc.on.doc.fill")
                        .font(.title2)
                        .foregroundStyle(Color.accentColor)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(itemsSummaryText)
                            .font(.headline)
                        Text(formatTotalBytes())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding()
                .background(.ultraThinMaterial)

                Divider()

                if let sendingTo = activeTransferringDevice {
                    // Active sending UI
                    VStack(spacing: 16) {
                        Spacer()
                        ProgressView(value: transferProgress)
                            .progressViewStyle(.linear)
                            .padding(.horizontal, 32)

                        Text("Sending to \(sendingTo.name)...")
                            .font(.headline)

                        Text("\(Int(transferProgress * 100))%")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                } else {
                    // Recipient List
                    List {
                        Section(header: Text("Choose Destination Device")) {
                            if devices.isEmpty {
                                Text("No paired devices found nearby.")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(devices) { device in
                                    Button {
                                        startSending(to: device)
                                    } label: {
                                        HStack(spacing: 12) {
                                            Image(systemName: iconForPlatform(device.platform))
                                                .font(.title3)
                                                .foregroundStyle(Color.accentColor)
                                                .frame(width: 30)

                                            VStack(alignment: .leading, spacing: 2) {
                                                HStack {
                                                    Text(device.name)
                                                        .font(.body)
                                                        .bold()
                                                        .foregroundStyle(.primary)

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

                                            Image(systemName: "paperplane.fill")
                                                .font(.subheadline)
                                                .foregroundStyle(Color.accentColor)
                                        }
                                        .padding(.vertical, 4)
                                    }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Nearside")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
            }
        }
    }

    private var itemsSummaryText: String {
        if stagedFiles.count == 1 {
            return stagedFiles[0].lastPathComponent
        } else {
            return "\(stagedFiles.count) files to send"
        }
    }

    private func formatTotalBytes() -> String {
        let total = stagedFiles.reduce(Int64(0)) { acc, url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
            return acc + size
        }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useAll]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: total)
    }

    private func startSending(to device: NearsideDevice) {
        activeTransferringDevice = device
        // Simulate progress for immediate responsiveness before completing
        Task {
            for step in 1...10 {
                try? await Task.sleep(nanoseconds: 80_000_000)
                await MainActor.run {
                    self.transferProgress = Double(step) / 10.0
                }
            }
            await MainActor.run {
                onSelectRecipient(device)
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

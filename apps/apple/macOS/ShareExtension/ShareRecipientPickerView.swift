import SwiftUI

public struct ShareRecipientPickerView: View {
    let itemCount: Int
    let devices: [NearsideDevice]
    let onSelectDevice: (NearsideDevice) -> Void
    let onCancel: () -> Void

    @State private var selectedDevice: NearsideDevice?
    @State private var isTransferring: Bool = false
    @State private var progress: Double = 0.0

    public init(
        itemCount: Int,
        devices: [NearsideDevice],
        onSelectDevice: @escaping (NearsideDevice) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.itemCount = itemCount
        self.devices = devices
        self.onSelectDevice = onSelectDevice
        self.onCancel = onCancel
    }

    public var body: some View {
        VStack(spacing: 16) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share with Nearside")
                        .font(.headline)
                    Text("\(itemCount) item\(itemCount == 1 ? "" : "s") ready to send")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
            }

            Divider()

            if isTransferring, let device = selectedDevice {
                // Transfer progress state
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.blue.opacity(0.15))
                            .frame(width: 48, height: 48)
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.blue)
                    }

                    Text("Sending to \(device.name)...")
                        .font(.system(size: 13, weight: .medium))

                    ProgressView(value: progress)
                        .progressViewStyle(.linear)
                        .frame(width: 200)

                    Text("\(Int(progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                .padding(.vertical, 16)
            } else {
                // Device selection grid
                VStack(alignment: .leading, spacing: 8) {
                    Text("CHOOSE RECIPIENT")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)

                    if devices.isEmpty {
                        VStack(spacing: 6) {
                            Text("No nearby devices found")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Ensure the recipient device has Nearside active on the same Wi-Fi network.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(devices) { device in
                                    deviceCard(device: device)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }

            Spacer()
        }
        .padding(16)
        .frame(width: 360, height: 220)
    }

    private func deviceCard(device: NearsideDevice) -> some View {
        Button(action: {
            startTransfer(to: device)
        }) {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.accentColor.opacity(0.12))
                        .frame(width: 48, height: 48)

                    Image(systemName: device.platform.systemSymbolName)
                        .font(.system(size: 20))
                        .foregroundColor(.accentColor)
                }

                VStack(spacing: 2) {
                    Text(device.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Text(device.platform.displayName)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .frame(width: 88, height: 96)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
    }

    private func startTransfer(to device: NearsideDevice) {
        selectedDevice = device
        isTransferring = true
        progress = 0.1

        Task {
            for step in 1...10 {
                try? await Task.sleep(nanoseconds: 120_000_000)
                await MainActor.run {
                    self.progress = Double(step) / 10.0
                }
            }
            await MainActor.run {
                onSelectDevice(device)
            }
        }
    }
}

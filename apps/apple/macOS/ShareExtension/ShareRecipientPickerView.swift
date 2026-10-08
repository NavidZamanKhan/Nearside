import SwiftUI

public struct ShareRecipientPickerView: View {
    @ObservedObject var viewModel: ShareExtensionViewModel
    let onCancel: () -> Void
    let onComplete: () -> Void

    public init(
        viewModel: ShareExtensionViewModel,
        onCancel: @escaping () -> Void,
        onComplete: @escaping () -> Void
    ) {
        self.viewModel = viewModel
        self.onCancel = onCancel
        self.onComplete = onComplete
    }

    private var subtitleText: String {
        if viewModel.isExtracting {
            return "Preparing items..."
        }
        if viewModel.isCompleted {
            return "Sent successfully"
        }
        if viewModel.isTransferring {
            return "Sending..."
        }
        let count = viewModel.stagedURLs.count
        if count == 1, let first = viewModel.stagedURLs.first {
            return first.lastPathComponent
        }
        return "\(count) item\(count == 1 ? "" : "s") ready to send"
    }

    public var body: some View {
        VStack(spacing: 14) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Share with Nearside")
                        .font(.headline)
                    Text(subtitleText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button(viewModel.isCompleted ? "Done" : "Cancel") {
                    if viewModel.isTransferring {
                        viewModel.cancelCurrentTransfer()
                    }
                    if viewModel.isCompleted {
                        onComplete()
                    } else {
                        onCancel()
                    }
                }
                .buttonStyle(.plain)
                .foregroundColor(.secondary)
            }

            Divider()

            if viewModel.isExtracting {
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(.circular)
                    Text("Loading files to share...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxHeight: .infinity)
            } else if let error = viewModel.errorMessage {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 28))
                        .foregroundColor(.orange)
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 16)
                    Button("Try Again") {
                        if let dev = viewModel.selectedDevice {
                            viewModel.startTransfer(to: dev, onComplete: onComplete)
                        } else {
                            viewModel.errorMessage = nil
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
                .frame(maxHeight: .infinity)
            } else if viewModel.isCompleted, let device = viewModel.selectedDevice {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 36))
                        .foregroundColor(.green)
                    Text("Delivered to \(device.name)")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Saved to Downloads on device")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxHeight: .infinity)
            } else if viewModel.isTransferring, let device = viewModel.selectedDevice {
                VStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.15))
                            .frame(width: 48, height: 48)
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.accentColor)
                    }

                    Text("Sending to \(device.name)...")
                        .font(.system(size: 13, weight: .medium))

                    ProgressView(value: viewModel.progress)
                        .progressViewStyle(.linear)
                        .frame(width: 220)

                    Text("\(Int(viewModel.progress * 100))%")
                        .font(.caption.monospacedDigit())
                        .foregroundColor(.secondary)
                }
                .frame(maxHeight: .infinity)
            } else {
                // Device selection
                VStack(alignment: .leading, spacing: 8) {
                    Text("CHOOSE RECIPIENT")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(.secondary)

                    if viewModel.devices.isEmpty {
                        VStack(spacing: 6) {
                            Text("No nearby devices found")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Text("Ensure the recipient device has Nearside open on Wi-Fi.")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(viewModel.devices) { device in
                                    deviceCard(device: device)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .frame(maxHeight: .infinity)
            }

            Spacer()
        }
        .padding(16)
        .frame(width: 360, height: 230)
    }

    private func deviceCard(device: NearsideDevice) -> some View {
        Button(action: {
            viewModel.startTransfer(to: device, onComplete: onComplete)
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
            .frame(width: 92, height: 96)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            .cornerRadius(10)
        }
        .buttonStyle(.plain)
        .disabled(viewModel.stagedURLs.isEmpty || viewModel.isExtracting)
    }
}

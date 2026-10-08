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
            return "Delivered"
        }
        if viewModel.isTransferring {
            return "Transferring..."
        }
        let count = viewModel.stagedURLs.count
        if count == 0 {
            return "No items to send"
        }
        let sizeStr = viewModel.totalBytes > 0 ? ByteCountFormatter.string(fromByteCount: viewModel.totalBytes, countStyle: .file) : ""
        if count == 1, let first = viewModel.stagedURLs.first {
            return sizeStr.isEmpty ? first.lastPathComponent : "\(first.lastPathComponent) (\(sizeStr))"
        }
        return sizeStr.isEmpty ? "\(count) items" : "\(count) items (\(sizeStr))"
    }

    public var body: some View {
        VStack(spacing: 12) {
            // Header bar
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [Color.accentColor, Color.blue],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 32, height: 32)
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Share with Nearside")
                        .font(.system(size: 14, weight: .bold))
                    Text(subtitleText)
                        .font(.system(size: 11))
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
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            Divider()

            // Main Content Area
            if viewModel.isExtracting {
                VStack(spacing: 12) {
                    ProgressView()
                        .progressViewStyle(.circular)
                        .controlSize(.regular)
                    Text("Preparing files to share...")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = viewModel.errorMessage {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.orange)

                    Text("Transfer Failed")
                        .font(.system(size: 14, weight: .semibold))

                    Text(error)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(.horizontal, 24)

                    HStack(spacing: 12) {
                        Button("Cancel") {
                            onCancel()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)

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
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.isCompleted, let device = viewModel.selectedDevice {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 38))
                        .foregroundColor(.green)

                    Text("Delivered to \(device.name)")
                        .font(.system(size: 14, weight: .semibold))

                    Text("File saved to Downloads folder")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    Button("Done") {
                        onComplete()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.isTransferring, let device = viewModel.selectedDevice {
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(Color.accentColor.opacity(0.12))
                            .frame(width: 56, height: 56)
                        Image(systemName: device.platform.systemSymbolName)
                            .font(.system(size: 26))
                            .foregroundColor(.accentColor)
                    }

                    VStack(spacing: 3) {
                        Text("Sending to \(device.name)...")
                            .font(.system(size: 13, weight: .semibold))

                        if viewModel.totalBytes > 0 {
                            let sentStr = ByteCountFormatter.string(fromByteCount: viewModel.transferredBytes, countStyle: .file)
                            let totalStr = ByteCountFormatter.string(fromByteCount: viewModel.totalBytes, countStyle: .file)
                            Text("\(sentStr) of \(totalStr)")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        } else {
                            Text("Connecting...")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }

                    VStack(spacing: 6) {
                        ProgressView(value: viewModel.progress, total: 1.0)
                            .progressViewStyle(.linear)
                            .frame(width: 260)

                        Text("\(Int(viewModel.progress * 100))%")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundColor(.secondary)
                    }

                    Button("Cancel") {
                        viewModel.cancelCurrentTransfer()
                        onCancel()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Device selection
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("CHOOSE RECIPIENT")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.secondary)
                        Spacer()
                        if !viewModel.devices.isEmpty {
                            Button("Rescan") {
                                viewModel.rescanDevices()
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 10))
                            .foregroundColor(.accentColor)
                        }
                    }

                    if viewModel.devices.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "antenna.radiowaves.left.and.right")
                                .font(.system(size: 30))
                                .foregroundColor(.secondary)
                            VStack(spacing: 4) {
                                Text("No nearby devices found")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(.primary)
                                Text("Ensure Nearside is open on the target device on Wi-Fi.")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                            }
                            Button("Scan Again") {
                                viewModel.rescanDevices()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(viewModel.devices) { device in
                                    RecipientDeviceCard(
                                        device: device,
                                        isEnabled: !viewModel.stagedURLs.isEmpty && !viewModel.isExtracting,
                                        onSelect: {
                                            viewModel.startTransfer(to: device, onComplete: onComplete)
                                        }
                                    )
                                }
                            }
                            .padding(.horizontal, 2)
                            .padding(.vertical, 4)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(18)
        .frame(width: 440, height: 280)
    }
}

private struct RecipientDeviceCard: View {
    let device: NearsideDevice
    let isEnabled: Bool
    let onSelect: () -> Void
    @State private var isHovered: Bool = false

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: 8) {
                ZStack(alignment: .bottomTrailing) {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.accentColor.opacity(isHovered ? 0.25 : 0.15),
                                    Color.accentColor.opacity(isHovered ? 0.15 : 0.08)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: 52, height: 52)

                    Image(systemName: device.platform.systemSymbolName)
                        .font(.system(size: 22, weight: .medium))
                        .foregroundColor(.accentColor)

                    Circle()
                        .fill(device.reachability == .online ? Color.green : Color.orange)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Color(NSColor.windowBackgroundColor), lineWidth: 2))
                        .offset(x: 2, y: 2)
                }

                VStack(spacing: 2) {
                    Text(device.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(device.platform.displayName)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            .frame(width: 116, height: 120)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(isHovered ? Color.accentColor.opacity(0.08) : Color(NSColor.controlBackgroundColor).opacity(0.6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isHovered ? Color.accentColor.opacity(0.5) : Color(NSColor.separatorColor).opacity(0.3), lineWidth: isHovered ? 1.5 : 1)
            )
            .scaleEffect(isHovered ? 1.02 : 1.0)
            .animation(.easeInOut(duration: 0.15), value: isHovered)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

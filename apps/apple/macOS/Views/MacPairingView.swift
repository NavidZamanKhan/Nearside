import SwiftUI
import AppKit
import CoreImage

/// The shelf and Preferences use the same expiring, authenticated pairing session.
@MainActor
struct MacPairingView: View {
    @ObservedObject var appState: AppState
    let target: NearsideDevice?
    @Environment(\.dismiss) private var dismiss
    @State private var manualURI = ""
    @State private var manualMessage: String?
    @State private var isPairing = false
    @State private var ownedSessionId: String?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text(target.map { "Pair with \($0.name)" } ?? "Pair Device")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button("Done") { dismiss() }
                    .disabled(isPairing)
            }

            Text("Open Nearside on your phone and tap Scan QR.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if let target {
                Text("Selected identity: \(target.shortFingerprint)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            if let payload = appState.activePairingPayload, payload.sessionId == ownedSessionId {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    if payload.isExpired {
                        VStack(spacing: 8) {
                            Image(systemName: "clock.badge.exclamationmark")
                                .font(.system(size: 28))
                            Text("This code expired. Generate a new code to pair.")
                                .font(.caption)
                                .multilineTextAlignment(.center)
                        }
                        .foregroundColor(.secondary)
                        .frame(height: 180)
                    } else if let image = qrImage(payload.toURI()) {
                        Image(nsImage: image)
                            .interpolation(.none)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 180, height: 180)
                            .padding(6)
                            .background(Color.white)
                            .cornerRadius(8)
                            .accessibilityLabel("Nearside pairing QR code")
                    }
                }
                Text("Keep this code visible until your phone confirms pairing.")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }

            if let status = appState.pairingStatusMessage {
                Text(status)
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }

            Button("Generate New QR") { generateSession() }
                .controlSize(.small)
                .disabled(isPairing)

            DisclosureGroup("Paste a pairing link") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Paste a current Nearside QR link displayed by the other device.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    TextField("nearside://pair?...", text: $manualURI)
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .disabled(isPairing)
                    Button(isPairing ? "Verifying..." : "Verify and Pair", action: pairManualURI)
                        .buttonStyle(.borderedProminent)
                        .disabled(isPairing || manualURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if let manualMessage {
                        Text(manualMessage)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.top, 6)
            }
            .font(.caption)
        }
        .padding(18)
        .frame(width: 320)
        .onAppear { generateSession() }
        .onDisappear {
            if let ownedSessionId { appState.stopPairingSession(expectedSessionId: ownedSessionId) }
        }
    }

    private func generateSession() {
        manualMessage = nil
        ownedSessionId = appState.startPairingSession(expectedPeerIdentity: target?.fingerprint)?.sessionId
    }

    private func pairManualURI() {
        let input = manualURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let payload = QRPairingPayload.fromURI(input) else {
            showFailure(PairingError.malformedPayload.toNearsideError())
            return
        }
        guard !payload.isExpired else {
            showFailure(PairingError.sessionExpired.toNearsideError(correlationId: payload.sessionId))
            return
        }
        if let target, payload.hostIdentity != target.fingerprint {
            showFailure(NearsideError(code: .pairingVerificationFailed, operation: "pairSelectedPeer",
                message: "This QR code belongs to another device. Use the selected device's pairing code.",
                correlationId: payload.sessionId))
            return
        }
        isPairing = true
        manualMessage = "Verifying the device identity..."
        appState.pairWithQrPayload(payload, expectedIdentity: target?.fingerprint) { result in
            isPairing = false
            switch result {
            case .success:
                manualURI = ""
                dismiss()
            case .failure(let error):
                let failure = (error as? NearsideError) ?? NearsideError(code: .pairingVerificationFailed,
                    operation: "pairQR", message: "Pairing failed. Display a fresh code and retry.",
                    underlyingError: error, correlationId: payload.sessionId)
                showFailure(failure)
            }
        }
    }

    private func showFailure(_ error: NearsideError) {
        NearsideLogger.shared.error(error, state: "rejected")
        manualMessage = error.localizedDescription
    }

    private func qrImage(_ uri: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(uri.utf8), forKey: "inputMessage")
        guard let output = filter.outputImage else { return nil }
        let representation = NSCIImageRep(ciImage: output.transformed(by: CGAffineTransform(scaleX: 6, y: 6)))
        let image = NSImage(size: representation.size)
        image.addRepresentation(representation)
        return image
    }
}

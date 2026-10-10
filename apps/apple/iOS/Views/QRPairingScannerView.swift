import SwiftUI
import AVFoundation
import CryptoKit

public struct QRPairingScannerView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: Int = 0
    @State private var manualCode: String = ""
    @State private var peerName: String = ""
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var isProcessing: Bool = false

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Pairing Method", selection: $selectedTab) {
                    Text("Scan QR").tag(0)
                    Text("Short Code").tag(1)
                }
                .pickerStyle(.segmented)
                .padding()

                if selectedTab == 0 {
                    qrScannerTab
                } else {
                    shortCodeTab
                }
            }
            .navigationTitle("Pair New Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    private var qrScannerTab: some View {
        VStack(spacing: 20) {
            ZStack {
                CameraPreviewRepresentable { scannedText in
                    handleScannedCode(scannedText)
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.accentColor.opacity(0.6), lineWidth: 2)
                )

                // Viewfinder guide
                VStack {
                    Spacer()
                    Text("Align QR code within frame")
                        .font(.footnote)
                        .padding(8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 16)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 360)
            .padding(.horizontal)

            if let error = errorMessage {
                Text(error)
                    .font(.subheadline)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            if let success = successMessage {
                Text(success)
                    .font(.subheadline)
                    .foregroundStyle(.green)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer()
        }
    }

    private var shortCodeTab: some View {
        Form {
            Section(header: Text("Manual Verification Code")) {
                TextField("Peer Device Name", text: $peerName)
                    .textInputAutocapitalization(.words)

                TextField("8-Digit Code", text: $manualCode)
                    .keyboardType(.numberPad)
                    .onChange(of: manualCode) { _, newValue in
                        let filtered = newValue.filter { $0.isNumber }
                        if filtered.count > 8 {
                            manualCode = String(filtered.prefix(8))
                        } else {
                            manualCode = filtered
                        }
                    }
            }

            if let error = errorMessage {
                Section {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.footnote)
                }
            }

            if let success = successMessage {
                Section {
                    Text(success)
                        .foregroundStyle(.green)
                        .font(.footnote)
                }
            }

            Section {
                Button(action: verifyShortCode) {
                    HStack {
                        Spacer()
                        if isProcessing {
                            ProgressView()
                                .padding(.trailing, 8)
                        }
                        Text("Verify & Pair")
                            .bold()
                        Spacer()
                    }
                }
                .disabled(manualCode.count != 8 || peerName.trimmingCharacters(in: .whitespaces).isEmpty || isProcessing)
            }
        }
    }

    private func handleScannedCode(_ text: String) {
        guard !isProcessing else { return }
        guard let payload = QRPairingPayload.fromURI(text) else {
            errorMessage = "Invalid QR code format. Expected nearside://pair"
            return
        }

        isProcessing = true
        errorMessage = nil

        appState.pairWithQrPayload(payload) { result in
            isProcessing = false
            switch result {
            case .success:
                triggerHapticSuccess()
                successMessage = "Successfully paired with \(payload.hostName)"
                dismiss()
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    private func verifyShortCode() {
        guard manualCode.count == 8 else { return }
        isProcessing = true
        errorMessage = nil

        isProcessing = false
        errorMessage = "Short-code network verification is unavailable. Scan a current Nearside QR code."
    }

    private func triggerHapticSuccess() {
        #if canImport(UIKit)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        #endif
    }
}

// UIKit Camera Preview Wrapper
#if canImport(UIKit)
struct CameraPreviewRepresentable: UIViewControllerRepresentable {
    let onCodeScanned: (String) -> Void

    func makeUIViewController(context: Context) -> CameraViewController {
        let vc = CameraViewController()
        vc.onCodeScanned = onCodeScanned
        return vc
    }

    func updateUIViewController(_ uiViewController: CameraViewController, context: Context) {}
}

class CameraViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCodeScanned: ((String) -> Void)?
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        setupCamera()
    }

    private func setupCamera() {
        let session = AVCaptureSession()
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else {
            showFallbackUI()
            return
        }

        if session.canAddInput(input) {
            session.addInput(input)
        }

        let output = AVCaptureMetadataOutput()
        if session.canAddOutput(output) {
            session.addOutput(output)
            output.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            output.metadataObjectTypes = [.qr]
        }

        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        view.layer.addSublayer(layer)

        self.captureSession = session
        self.previewLayer = layer

        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    private func showFallbackUI() {
        let label = UILabel()
        label.text = "Camera Unavailable in Simulator"
        label.textColor = .lightGray
        label.font = .systemFont(ofSize: 14)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let stringValue = object.stringValue else { return }
        onCodeScanned?(stringValue)
    }
}
#endif

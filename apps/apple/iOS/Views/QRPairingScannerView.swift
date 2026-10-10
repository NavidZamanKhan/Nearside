import Foundation

/// Pauses capture after one result until the user explicitly retries.
struct QRScannerCaptureState {
    enum Phase: Equatable { case scanning, captured, pairing, completed, cancelled }
    private(set) var phase: Phase = .scanning
    var shouldScan: Bool { phase == .scanning }
    var isProcessing: Bool { phase == .pairing }

    mutating func capture() -> Bool {
        guard phase == .scanning else { return false }
        phase = .captured
        return true
    }

    mutating func beginPairing() -> Bool {
        guard phase == .captured else { return false }
        phase = .pairing
        return true
    }

    mutating func finishPairing(succeeded: Bool) {
        guard phase == .pairing else { return }
        phase = succeeded ? .completed : .captured
    }

    mutating func retry() {
        guard phase == .captured else { return }
        phase = .scanning
    }

    mutating func cancel() -> Bool {
        guard phase != .pairing && phase != .completed else { return false }
        phase = .cancelled
        return true
    }
}

#if os(iOS)
import SwiftUI
import AVFoundation
import UIKit

public struct QRPairingScannerView: View {
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var selectedTab: Int = 0
    @State private var manualCode: String = ""
    @State private var peerName: String = ""
    @State private var manualURI: String = ""
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var cameraFailure: NearsideError?
    @State private var captureState = QRScannerCaptureState()
    @State private var scannerCorrelationId = UUID().uuidString
    @State private var cameraGeneration = UUID()

    public init(appState: AppState) {
        self.appState = appState
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Pairing Method", selection: $selectedTab) {
                    Text("Scan QR").tag(0)
                    Text("Paste QR").tag(1)
                    Text("Short Code").tag(2)
                }
                .pickerStyle(.segmented)
                .padding()
                .disabled(captureState.isProcessing)

                if selectedTab == 0 {
                    qrScannerTab
                } else if selectedTab == 1 {
                    pasteQRTab
                } else {
                    shortCodeTab
                }
            }
            .navigationTitle("Pair New Device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        guard captureState.cancel() else { return }
                        NearsideLogger.shared.info("pairing", "scanQR", "QR scanner cancelled", state: "cancelled", correlationId: scannerCorrelationId)
                        dismiss()
                    }
                    .disabled(captureState.isProcessing)
                }
            }
            .interactiveDismissDisabled(captureState.isProcessing)
            .onDisappear {
                _ = captureState.cancel()
            }
        }
    }

    private var qrScannerTab: some View {
        VStack(spacing: 20) {
            ZStack {
                CameraPreviewRepresentable(
                    isScanning: captureState.shouldScan && scenePhase == .active,
                    onCodeScanned: handleScannedCode,
                    onCameraFailure: handleCameraFailure,
                    onCameraReady: { cameraFailure = nil }
                )
                .id(cameraGeneration)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(Color.accentColor.opacity(0.6), lineWidth: 2)
                )

                if let cameraFailure {
                    VStack(spacing: 14) {
                        Image(systemName: "camera.fill")
                            .font(.largeTitle)
                        Text(cameraFailure.message)
                            .multilineTextAlignment(.center)
                        if cameraFailure.code == .pairingCameraPermissionDenied {
                            Button("Open Settings") {
                                if let url = URL(string: UIApplication.openSettingsURLString) {
                                    UIApplication.shared.open(url)
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        } else {
                            Button("Try Camera Again") {
                                self.cameraFailure = nil
                                cameraGeneration = UUID()
                            }
                            .buttonStyle(.bordered)
                        }
                        Button("Paste a pairing QR instead") { selectedTab = 1 }
                            .buttonStyle(.bordered)
                    }
                    .foregroundStyle(.white)
                    .padding()
                } else {
                    VStack {
                        Spacer()
                        Text("Align QR code within frame")
                            .font(.footnote)
                            .padding(8)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(.bottom, 16)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: 360)
            .padding(.horizontal)

            pairingStatus

            if !captureState.shouldScan && !captureState.isProcessing && cameraFailure == nil {
                Button("Scan Again") {
                    errorMessage = nil
                    captureState.retry()
                }
                .buttonStyle(.bordered)
            }

            Spacer()
        }
    }

    private var pasteQRTab: some View {
        Form {
            Section("Current Nearside Pairing QR") {
                TextField("nearside://pair?...", text: $manualURI, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .privacySensitive()
                Text("Paste the complete pairing URI from the other device. It expires with that device's QR session.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Verify & Pair") {
                    captureState.retry()
                    handleScannedCode(manualURI.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .disabled(manualURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || captureState.isProcessing)
            }
            Section { pairingStatus }
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
                        manualCode = String(newValue.filter { $0.isNumber }.prefix(8))
                    }
                Text("Short-code network verification is unavailable. Scan a current Nearside QR code or use Paste QR to pair securely.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section {
                Button("Use Paste QR") { selectedTab = 1 }
            }
        }
    }

    @ViewBuilder
    private var pairingStatus: some View {
        if captureState.isProcessing {
            ProgressView("Verifying device...")
                .padding(.horizontal)
        }
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
    }

    private func handleScannedCode(_ text: String) {
        guard captureState.capture() else { return }
        guard let payload = QRPairingPayload.fromURI(text) else {
            let error = NearsideError(code: .pairingMalformedPayload, operation: "scanQR", message: "Invalid QR code. Scan a current Nearside pairing QR.", correlationId: scannerCorrelationId)
            NearsideLogger.shared.error(error, state: "rejected")
            errorMessage = error.localizedDescription
            return
        }
        guard captureState.beginPairing() else { return }
        errorMessage = nil
        cameraFailure = nil
        appState.pairWithQrPayload(payload) { result in
            captureState.finishPairing(succeeded: (try? result.get()) != nil)
            switch result {
            case .success(let peer):
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                successMessage = "Successfully paired with \(peer.name)"
                appState.clipboardToastMessage = successMessage
                dismiss()
            case .failure(let error):
                errorMessage = error.localizedDescription
            }
        }
    }

    private func handleCameraFailure(_ error: NearsideError) {
        let diagnostic = NearsideError(code: error.code, operation: "scanQR", message: error.message, underlyingError: error, correlationId: scannerCorrelationId)
        cameraFailure = diagnostic
        NearsideLogger.shared.error(diagnostic, state: "unavailable")
    }
}

struct CameraPreviewRepresentable: UIViewControllerRepresentable {
    let isScanning: Bool
    let onCodeScanned: (String) -> Void
    let onCameraFailure: (NearsideError) -> Void
    let onCameraReady: () -> Void

    func makeUIViewController(context: Context) -> CameraViewController {
        let controller = CameraViewController()
        controller.onCodeScanned = onCodeScanned
        controller.onCameraFailure = onCameraFailure
        controller.onCameraReady = onCameraReady
        controller.setScanning(isScanning)
        return controller
    }

    func updateUIViewController(_ controller: CameraViewController, context: Context) {
        controller.onCodeScanned = onCodeScanned
        controller.onCameraFailure = onCameraFailure
        controller.onCameraReady = onCameraReady
        controller.setScanning(isScanning)
    }

    static func dismantleUIViewController(_ controller: CameraViewController, coordinator: ()) {
        controller.setScanning(false)
    }
}

final class CameraViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCodeScanned: ((String) -> Void)?
    var onCameraFailure: ((NearsideError) -> Void)?
    var onCameraReady: (() -> Void)?
    private let sessionQueue = DispatchQueue(label: "com.nearside.qr-camera", qos: .userInitiated)
    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var wantsScanning = false
    private var isVisible = false
    private var isConfiguring = false
    private var didDeliverCode = false
    private var lastCameraError: NearsideErrorCode?
    private var cameraObservers: [NSObjectProtocol] = []
    private var cameraInterrupted = false
    private var runtimeFailed = false

    deinit {
        cameraObservers.forEach(NotificationCenter.default.removeObserver)
        if let session = captureSession {
            sessionQueue.async { if session.isRunning { session.stopRunning() } }
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isVisible = true
        updateCamera()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isVisible = false
        updateCamera()
    }

    func setScanning(_ enabled: Bool) {
        if enabled && !wantsScanning { didDeliverCode = false }
        wantsScanning = enabled
        if isViewLoaded { updateCamera() }
    }

    private func updateCamera() {
        guard wantsScanning && isVisible else {
            if let session = captureSession {
                sessionQueue.async { if session.isRunning { session.stopRunning() } }
            }
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            guard !isConfiguring else { return }
            isConfiguring = true
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isConfiguring = false
                    guard self.wantsScanning && self.isVisible else { return }
                    if granted { self.updateCamera() }
                    else { self.reportCameraError(.pairingCameraPermissionDenied, "Camera permission is denied. Allow camera access in Settings or paste a pairing QR.") }
                }
            }
        case .denied, .restricted:
            reportCameraError(.pairingCameraPermissionDenied, "Camera permission is denied. Allow camera access in Settings or paste a pairing QR.")
        case .authorized:
            guard !cameraInterrupted && !runtimeFailed else { return }
            let recovered = lastCameraError != nil
            lastCameraError = nil
            if recovered {
                DispatchQueue.main.async { [weak self] in self?.onCameraReady?() }
            }
            if let session = captureSession {
                sessionQueue.async { if !session.isRunning { session.startRunning() } }
            } else {
                configureCamera()
            }
        @unknown default:
            reportCameraError(.pairingCameraUnavailable, "The camera is unavailable. Paste a pairing QR to continue.")
        }
    }

    private func configureCamera() {
        guard !isConfiguring else { return }
        guard let device = AVCaptureDevice.default(for: .video) else {
            reportCameraError(.pairingCameraUnavailable, "No camera is available. Paste a pairing QR to continue.")
            return
        }
        isConfiguring = true
        sessionQueue.async { [weak self] in
            let session = AVCaptureSession()
            session.beginConfiguration()
            do {
                let input = try AVCaptureDeviceInput(device: device)
                let output = AVCaptureMetadataOutput()
                guard session.canAddInput(input) else {
                    throw NearsideError(code: .pairingCameraUnavailable, operation: "configureCamera", message: "Camera input is unavailable")
                }
                session.addInput(input)
                guard session.canAddOutput(output) else {
                    throw NearsideError(code: .pairingCameraUnavailable, operation: "configureCamera", message: "QR camera output is unavailable")
                }
                session.addOutput(output)
                guard output.availableMetadataObjectTypes.contains(.qr) else {
                    throw NearsideError(code: .pairingCameraUnavailable, operation: "configureCamera", message: "QR detection is unavailable")
                }
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]
                session.commitConfiguration()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isConfiguring = false
                    self.captureSession = session
                    let layer = AVCaptureVideoPreviewLayer(session: session)
                    layer.videoGravity = .resizeAspectFill
                    layer.frame = self.view.bounds
                    self.view.layer.insertSublayer(layer, at: 0)
                    self.previewLayer = layer
                    let rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: layer)
                    self.rotationCoordinator = rotation
                    self.rotationObservation = rotation.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
                        let angle = coordinator.videoRotationAngleForHorizonLevelPreview
                        DispatchQueue.main.async { self?.updatePreviewRotation(angle) }
                    }
                    self.observeCamera(session)
                    self.onCameraReady?()
                    self.updateCamera()
                }
            } catch {
                session.commitConfiguration()
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.isConfiguring = false
                    self.reportCameraError(.pairingCameraUnavailable, "The camera could not start. Paste a pairing QR to continue.", underlyingError: error)
                }
            }
        }
    }

    private func reportCameraError(_ code: NearsideErrorCode, _ message: String, underlyingError: Error? = nil) {
        guard lastCameraError != code else { return }
        lastCameraError = code
        onCameraFailure?(NearsideError(code: code, operation: "scanQR", message: message, underlyingError: underlyingError))
    }

    private func observeCamera(_ session: AVCaptureSession) {
        let notifications = NotificationCenter.default
        cameraObservers.append(notifications.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: .main) { [weak self] notification in
            let cause = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
            self?.runtimeFailed = true
            self?.setScanning(false)
            self?.reportCameraError(.pairingCameraUnavailable, "The camera stopped unexpectedly. Paste a pairing QR to continue.", underlyingError: cause)
        })
        cameraObservers.append(notifications.addObserver(forName: .AVCaptureSessionWasInterrupted, object: session, queue: .main) { [weak self] _ in
            self?.cameraInterrupted = true
            self?.reportCameraError(.pairingCameraUnavailable, "The camera is temporarily unavailable. Close other camera apps or paste a pairing QR.")
        })
        cameraObservers.append(notifications.addObserver(forName: .AVCaptureSessionInterruptionEnded, object: session, queue: .main) { [weak self] _ in
            self?.cameraInterrupted = false
            self?.updateCamera()
        })
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
        if let angle = rotationCoordinator?.videoRotationAngleForHorizonLevelPreview {
            updatePreviewRotation(angle)
        }
    }

    private func updatePreviewRotation(_ angle: CGFloat) {
        if let connection = previewLayer?.connection, connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard wantsScanning && isVisible && !didDeliverCode && lastCameraError == nil,
              let object = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let value = object.stringValue else { return }
        didDeliverCode = true
        setScanning(false)
        onCodeScanned?(value)
    }
}
#endif

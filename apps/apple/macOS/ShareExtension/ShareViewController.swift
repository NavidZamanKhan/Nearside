import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Network
import Combine

@MainActor
public final class ShareExtensionViewModel: ObservableObject {
    @Published public var stagedURLs: [URL] = []
    @Published public var isExtracting: Bool = true
    @Published public var extractionError: String? = nil

    @Published public var devices: [NearsideDevice] = []
    @Published public var selectedDevice: NearsideDevice? = nil

    @Published public var isTransferring: Bool = false
    @Published public var isCompleted: Bool = false
    @Published public var progress: Double = 0.0
    @Published public var transferredBytes: Int64 = 0
    @Published public var totalBytes: Int64 = 0
    @Published public var errorMessage: String? = nil

    private var activeTransferId: String? = nil
    private var stagingDirectory: URL? = nil

    public init() {
        self.devices = []
        self.loadEnrolledDevices()
        self.startDiscovery()
    }

    private func loadEnrolledDevices() {
        let store = PinnedTrustStore()
        let peers = store.allEnrolledPeers()
        var updated: [NearsideDevice] = []
        for p in peers {
            let platform: DevicePlatform = (p.platformRaw.lowercased() == "android") ? .android : .macOS
            updated.append(
                NearsideDevice(
                    id: p.identity,
                    name: p.name,
                    platform: platform,
                    fingerprint: p.identity,
                    ipAddress: "192.168.0.100",
                    port: 41433,
                    reachability: .online,
                    lastSeen: Date()
                )
            )
        }
        self.devices = updated
    }

    private func startDiscovery() {
        DiscoveryService.shared.onDiscoveredDevicesChanged = { [weak self] discovered in
            Task { @MainActor in
                guard let self = self else { return }
                var merged = self.devices
                for d in discovered {
                    if let idx = merged.firstIndex(where: { $0.id == d.id }) {
                        merged[idx] = d
                    } else {
                        merged.append(d)
                    }
                }
                self.devices = merged
            }
        }
        DiscoveryService.shared.ensureBrowsingActive()
    }

    public func extractFiles(from items: [NSExtensionItem]) async {
        isExtracting = true
        extractionError = nil

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("NearsideShare_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.stagingDirectory = dir

        var urls: [URL] = []
        for item in items {
            guard let attachments = item.attachments else { continue }
            for provider in attachments {
                if let url = await extractSingleProvider(provider, stagingDir: dir) {
                    urls.append(url)
                }
            }
        }

        if urls.isEmpty {
            self.isExtracting = false
            self.extractionError = "No shareable items found"
            return
        }

        self.stagedURLs = urls
        self.isExtracting = false
    }

    private func extractSingleProvider(_ provider: NSItemProvider, stagingDir: URL) async -> URL? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            if let fileUrl = await loadItemURL(provider: provider, type: UTType.fileURL.identifier) {
                return stageURL(fileUrl, stagingDir: stagingDir)
            }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.item.identifier) {
            if let fileUrl = await loadItemURL(provider: provider, type: UTType.item.identifier) {
                return stageURL(fileUrl, stagingDir: stagingDir)
            }
        }

        let candidateTypes = [
            UTType.content.identifier,
            UTType.data.identifier,
            UTType.image.identifier,
            UTType.movie.identifier,
            UTType.pdf.identifier
        ]
        for type in candidateTypes {
            if provider.hasItemConformingToTypeIdentifier(type) {
                if let repUrl = await loadFileRep(provider: provider, type: type, stagingDir: stagingDir) {
                    return repUrl
                }
            }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            if let text = await loadText(provider: provider) {
                let dest = stagingDir.appendingPathComponent("shared_text_\(Int(Date().timeIntervalSince1970)).txt")
                if (try? text.data(using: .utf8)?.write(to: dest)) != nil {
                    return dest
                }
            }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = await loadItemURL(provider: provider, type: UTType.url.identifier) {
                if url.isFileURL {
                    return stageURL(url, stagingDir: stagingDir)
                } else {
                    let dest = stagingDir.appendingPathComponent("shared_link_\(Int(Date().timeIntervalSince1970)).url")
                    let shortcut = "[InternetShortcut]\r\nURL=\(url.absoluteString)\r\n"
                    if (try? shortcut.data(using: .utf8)?.write(to: dest)) != nil {
                        return dest
                    }
                }
            }
        }

        return nil
    }

    private func stageURL(_ source: URL, stagingDir: URL) -> URL {
        let isSecurityScoped = source.startAccessingSecurityScopedResource()
        let name = source.lastPathComponent.isEmpty ? "file_\(UUID().uuidString.prefix(6))" : source.lastPathComponent
        let target = stagingDir.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: target)

        do {
            try FileManager.default.copyItem(at: source, to: target)
            if isSecurityScoped { source.stopAccessingSecurityScopedResource() }
            return target
        } catch {
            if let data = try? Data(contentsOf: source) {
                if (try? data.write(to: target)) != nil {
                    if isSecurityScoped { source.stopAccessingSecurityScopedResource() }
                    return target
                }
            }
            return source
        }
    }

    private func loadFileRep(provider: NSItemProvider, type: String, stagingDir: URL) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { tempURL, _ in
                guard let tempURL = tempURL else {
                    continuation.resume(returning: nil)
                    return
                }
                let name = tempURL.lastPathComponent.isEmpty ? "file_\(UUID().uuidString.prefix(6))" : tempURL.lastPathComponent
                let target = stagingDir.appendingPathComponent(name)
                try? FileManager.default.removeItem(at: target)
                do {
                    try FileManager.default.copyItem(at: tempURL, to: target)
                    continuation.resume(returning: target)
                } catch {
                    if let data = try? Data(contentsOf: tempURL), (try? data.write(to: target)) != nil {
                        continuation.resume(returning: target)
                        return
                    }
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func loadItemURL(provider: NSItemProvider, type: String) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let nsUrl = item as? NSURL {
                    continuation.resume(returning: nsUrl as URL)
                } else if let data = item as? Data {
                    if let s = String(data: data, encoding: .utf8), let u = URL(string: s) {
                        continuation.resume(returning: u)
                    } else if let u = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSURL.self, from: data) {
                        continuation.resume(returning: u as URL)
                    } else {
                        continuation.resume(returning: nil)
                    }
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func loadText(provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                if let s = item as? String {
                    continuation.resume(returning: s)
                } else if let ns = item as? NSString {
                    continuation.resume(returning: ns as String)
                } else if let data = item as? Data, let s = String(data: data, encoding: .utf8) {
                    continuation.resume(returning: s)
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    public func startTransfer(to device: NearsideDevice, onComplete: @escaping () -> Void) {
        guard !stagedURLs.isEmpty else {
            errorMessage = "No files selected to share"
            return
        }

        selectedDevice = device
        isTransferring = true
        isCompleted = false
        progress = 0.05
        errorMessage = nil

        let senderId = DeviceIdentity.defaultEnrolledIdentity

        NearsideLogger.shared.info(
            "share",
            "startTransfer",
            "Initiating share sheet transfer to \(device.name)",
            state: "transferring",
            metadata: ["target": device.ipAddress ?? "none", "filesCount": "\(stagedURLs.count)"]
        )

        TransferEngine.shared.sendFiles(
            files: stagedURLs,
            to: device,
            senderId: senderId,
            retryPolicy: RetryPolicy(maxAttempts: 3, initialDelay: 0.3, multiplier: 1.5),
            onProgress: { [weak self] fraction, transferred, total in
                Task { @MainActor in
                    guard let self = self else { return }
                    self.progress = max(0.05, fraction)
                    self.transferredBytes = transferred
                    self.totalBytes = total
                }
            },
            completion: { [weak self] result in
                Task { @MainActor in
                    guard let self = self else { return }
                    switch result {
                    case .success:
                        self.progress = 1.0
                        self.isCompleted = true
                        NearsideLogger.shared.info("share", "startTransfer", "Transfer complete", state: "completed")
                        try? await Task.sleep(nanoseconds: 700_000_000)
                        self.cleanup()
                        onComplete()
                    case .failure(let err):
                        self.isTransferring = false
                        self.errorMessage = err.localizedDescription
                        NearsideLogger.shared.warn("share", "startTransfer", "Transfer failed: \(err.localizedDescription)")
                    }
                }
            }
        )
    }

    public func cancelCurrentTransfer() {
        if let id = activeTransferId {
            TransferEngine.shared.cancelTransfer(id: id)
        }
        cleanup()
    }

    private func cleanup() {
        if let dir = stagingDirectory {
            try? FileManager.default.removeItem(at: dir)
        }
    }
}

@objc(ShareViewController)
public final class ShareViewController: NSViewController {

    private var viewModel = ShareExtensionViewModel()
    private var hostingController: NSHostingController<ShareRecipientPickerView>?

    public override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 230))
        self.preferredContentSize = NSSize(width: 360, height: 230)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()

        let pickerView = ShareRecipientPickerView(
            viewModel: viewModel,
            onCancel: { [weak self] in
                self?.cancelShare()
            },
            onComplete: { [weak self] in
                self?.completeShare()
            }
        )

        let hosting = NSHostingController(rootView: pickerView)
        self.hostingController = hosting
        addChild(hosting)
        hosting.view.frame = self.view.bounds
        hosting.view.autoresizingMask = [.width, .height]
        self.view.addSubview(hosting.view)

        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        Task { [weak self] in
            await self?.viewModel.extractFiles(from: items)
        }
    }

    private func completeShare() {
        extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
    }

    private func cancelShare() {
        let cancelError = NSError(
            domain: NSCocoaErrorDomain,
            code: NSUserCancelledError,
            userInfo: [NSLocalizedDescriptionKey: "User cancelled share request"]
        )
        extensionContext?.cancelRequest(withError: cancelError)
    }
}

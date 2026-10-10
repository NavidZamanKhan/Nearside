import AppKit
import SwiftUI
import UniformTypeIdentifiers
import Combine

@MainActor
public final class ShareExtensionViewModel: ObservableObject {
    @Published public var stagedURLs: [URL] = []
    @Published public var isExtracting: Bool = true
    @Published public var extractionError: String? = nil

    @Published public var isCompleted: Bool = false
    @Published public var totalBytes: Int64 = 0
    @Published public var errorMessage: String? = nil

    @Published public var isOpeningHost = false
    private var stagingDirectory: URL?
    private var handoffTask: Task<Void, Never>?

    public init() {
        // The extension never loads the host's keys or trust store.
    }

    public func extractFiles(from items: [NSExtensionItem]) async {
        isExtracting = true
        extractionError = nil

        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.nearside.share/Requests", isDirectory: true)
        MacShareHandoff.removeExpiredRequests(in: root)
        let dir: URL
        do {
            dir = try MacShareHandoff.makeDirectory(in: root)
            stagingDirectory = dir
        } catch {
            report(error, fallback: .storageWriteFailed, message: "Could not prepare the shared files.")
            isExtracting = false
            return
        }

        var urls: [URL] = []
        var failedCount = 0
        for item in items {
            guard let attachments = item.attachments else { continue }
            for provider in attachments {
                if let url = await extractSingleProvider(provider, stagingDir: dir) {
                    urls.append(url)
                } else {
                    failedCount += 1
                }
            }
        }

        if failedCount > 0 {
            isExtracting = false
            let failure = MacShareHandoff.failure(.storageReadFailed,
                "One or more items could not be prepared. Select accessible regular files and try again.")
            extractionError = failure.localizedDescription
            NearsideLogger.shared.error(failure, state: "failed")
            cleanup()
            return
        }
        if urls.isEmpty {
            self.isExtracting = false
            self.extractionError = "No shareable items found"
            return
        }

        self.stagedURLs = urls
        var total: Int64 = 0
        for u in urls {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: u.path),
               let size = attrs[.size] as? Int64 {
                total += size
            }
        }
        self.totalBytes = total
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
            if let text = await loadText(provider: provider), let data = text.data(using: .utf8) {
                return try? MacShareHandoff.stage(data: data, name: "shared_text.txt", in: stagingDir)
            }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            if let url = await loadItemURL(provider: provider, type: UTType.url.identifier) {
                if url.isFileURL {
                    return stageURL(url, stagingDir: stagingDir)
                } else {
                    let shortcut = "[InternetShortcut]\r\nURL=\(url.absoluteString)\r\n"
                    if let data = shortcut.data(using: .utf8) {
                        return try? MacShareHandoff.stage(data: data, name: "shared_link.url", in: stagingDir)
                    }
                }
            }
        }

        return nil
    }

    private func stageURL(_ source: URL, stagingDir: URL) -> URL? {
        do { return try MacShareHandoff.stage(source, in: stagingDir) }
        catch {
            report(error, fallback: .storageReadFailed, message: "Could not read a shared file. Check access and try again.")
            return nil
        }
    }

    private func loadFileRep(provider: NSItemProvider, type: String, stagingDir: URL) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type) { tempURL, _ in
                guard let tempURL = tempURL else {
                    continuation.resume(returning: nil)
                    return
                }
                do {
                    // NSItemProvider only guarantees access inside this callback.
                    continuation.resume(returning: try MacShareHandoff.stage(tempURL, in: stagingDir))
                } catch {
                    let failure = MacShareHandoff.failure(.storageReadFailed,
                        "Could not copy the shared item from its provider.", cause: error)
                    NearsideLogger.shared.error(failure, state: "failed")
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
                } else if let s = item as? String {
                    let u = URL(string: s) ?? URL(fileURLWithPath: s)
                    continuation.resume(returning: u)
                } else if let ns = item as? NSString {
                    let u = URL(string: ns as String) ?? URL(fileURLWithPath: ns as String)
                    continuation.resume(returning: u)
                } else if let data = item as? Data {
                    var isStale = false
                    if let bookmarkURL = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                        continuation.resume(returning: bookmarkURL)
                    } else if let s = String(data: data, encoding: .utf8) {
                        let u = URL(string: s) ?? URL(fileURLWithPath: s)
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

    public func openInNearside(onComplete: @escaping () -> Void) {
        guard !isOpeningHost, let directory = stagingDirectory, !stagedURLs.isEmpty else { return }
        isOpeningHost = true
        errorMessage = nil
        handoffTask = Task { [weak self] in
            guard let self else { return }
            do {
                let requestURL = try MacShareHandoff.writeRequest(files: stagedURLs, in: directory)
                let hostURL = Bundle.main.bundleURL.deletingLastPathComponent()
                    .deletingLastPathComponent().deletingLastPathComponent()
                guard Bundle(url: hostURL)?.bundleIdentifier == "com.nearside.app.macos" else {
                    throw MacShareHandoff.failure(.connectionRefused,
                        "Open the installed Nearside app, then try sharing again.")
                }
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    NSWorkspace.shared.open([requestURL], withApplicationAt: hostURL,
                        configuration: configuration) { _, error in
                        if let error { continuation.resume(throwing: error) }
                        else { continuation.resume() }
                    }
                }
                // Keep provider copies alive until the host confirms its own copies.
                for _ in 0..<100 {
                    try Task.checkCancellation()
                    if MacShareHandoff.isAcknowledged(requestURL: requestURL) {
                        cleanup()
                        isCompleted = true
                        onComplete()
                        return
                    }
                    try await Task.sleep(nanoseconds: 200_000_000)
                }
                throw MacShareHandoff.failure(.connectionTimedOut,
                    "Nearside did not import the files. Open Nearside and try again.")
            } catch is CancellationError {
                return
            } catch {
                report(error, fallback: .connectionRefused, message: "Could not open the share in Nearside. Open Nearside and try again.")
                isOpeningHost = false
            }
        }
    }

    public func cancelCurrentTransfer() {
        handoffTask?.cancel()
        // Once a handoff is in flight retain files until acknowledged or expiry;
        // launch completion alone does not mean the host has read them yet.
        if !isOpeningHost { cleanup() }
    }

    private func report(_ error: Error, fallback: NearsideErrorCode, message: String) {
        let failure = (error as? NearsideError) ?? MacShareHandoff.failure(fallback, message, cause: error)
        errorMessage = failure.localizedDescription
        NearsideLogger.shared.error(failure, state: "failed")
    }

    private func cleanup() {
        if let directory = stagingDirectory {
            try? FileManager.default.removeItem(at: directory)
            stagingDirectory = nil
        }
    }

}

@objc(ShareViewController)
public final class ShareViewController: NSViewController {

    private var viewModel = ShareExtensionViewModel()
    private var hostingController: NSHostingController<ShareRecipientPickerView>?

    public override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 280))
        self.preferredContentSize = NSSize(width: 440, height: 280)
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
        viewModel.cancelCurrentTransfer()
        let cancelError = NSError(
            domain: NSCocoaErrorDomain,
            code: NSUserCancelledError,
            userInfo: [NSLocalizedDescriptionKey: "User cancelled share request"]
        )
        extensionContext?.cancelRequest(withError: cancelError)
    }
}

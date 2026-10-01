import Cocoa
import UniformTypeIdentifiers

@objc(ShareViewController)
public class ShareViewController: NSViewController {

    private let coordinator = StagingCoordinator()
    private var stagedItems: [JobItem] = []
    private var statusLabel: NSTextField!

    public override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 200))
        self.view.wantsLayer = true
        self.view.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let titleLabel = NSTextField(labelWithString: "Nearside Share")
        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .bold)
        titleLabel.frame = NSRect(x: 20, y: 160, width: 300, height: 22)
        self.view.addSubview(titleLabel)

        statusLabel = NSTextField(labelWithString: "Processing shared items...")
        statusLabel.font = NSFont.systemFont(ofSize: 12)
        statusLabel.textColor = NSColor.secondaryLabelColor
        statusLabel.frame = NSRect(x: 20, y: 100, width: 300, height: 50)
        self.view.addSubview(statusLabel)

        let cancelButton = NSButton(title: "Cancel", target: self, action: #selector(cancelAction))
        cancelButton.frame = NSRect(x: 150, y: 20, width: 80, height: 32)
        self.view.addSubview(cancelButton)

        let sendButton = NSButton(title: "Send", target: self, action: #selector(sendAction))
        sendButton.bezelStyle = .rounded
        sendButton.keyEquivalent = "\r"
        sendButton.frame = NSRect(x: 240, y: 20, width: 80, height: 32)
        self.view.addSubview(sendButton)
    }

    public override func viewDidLoad() {
        super.viewDidLoad()
        extractAndStageItems()
    }

    private func extractAndStageItems() {
        guard let extensionItem = extensionContext?.inputItems.first as? NSExtensionItem,
              let attachments = extensionItem.attachments, !attachments.isEmpty else {
            statusLabel.stringValue = "No valid items shared."
            return
        }

        statusLabel.stringValue = "Staging \(attachments.count) item(s)..."

        Task {
            var items: [JobItem] = []
            for provider in attachments {
                if provider.hasItemConformingToTypeIdentifier(UTType.item.identifier) {
                    let item = await stageProviderItem(provider: provider)
                    if let item = item {
                        items.append(item)
                    }
                }
            }

            await MainActor.run {
                self.stagedItems = items
                let totalBytes = items.reduce(0) { $0 + $1.sizeBytes }
                let formattedSize = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
                self.statusLabel.stringValue = "Ready: \(items.count) item(s) (\(formattedSize))\nTarget: Paired MacBook Pro"
            }
        }
    }

    private func stageProviderItem(provider: NSItemProvider) async -> JobItem? {
        let suggestedName = provider.suggestedName
        return await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) { url, error in
                guard let sourceUrl = url, error == nil else {
                    continuation.resume(returning: nil)
                    return
                }

                // CRITICAL E2 INVARIANT:
                // Eagerly copy into staging before loadFileRepresentation callback exits!
                do {
                    let staged = try self.coordinator.stageFileFromUrl(sourceUrl: sourceUrl, originalName: suggestedName)
                    continuation.resume(returning: staged)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    @objc private func sendAction() {
        guard !stagedItems.isEmpty else {
            cancelAction()
            return
        }

        do {
            let manifest = JobManifest(jobId: UUID().uuidString, items: stagedItems)
            _ = try coordinator.saveManifest(manifest)

            // Complete request to host app
            self.extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
        } catch {
            cancelAction()
        }
    }

    @objc private func cancelAction() {
        let error = NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError, userInfo: nil)
        self.extensionContext?.cancelRequest(withError: error)
    }
}

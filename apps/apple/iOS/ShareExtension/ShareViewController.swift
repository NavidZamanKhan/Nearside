import UIKit
import SwiftUI
import UniformTypeIdentifiers

@objc(ShareViewController)
public final class ShareViewController: UIViewController {

    private var stagedFiles: [URL] = []
    private var stagingDirectory: URL?
    private var pairedDevices: [NearsideDevice] = []

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        loadPairedDevices()
        stageAttachmentsAndPresent()
    }

    private func loadPairedDevices() {
        let trustStore = PinnedTrustStore()
        let enrolled = trustStore.allEnrolledPeers()

        if !enrolled.isEmpty {
            self.pairedDevices = enrolled.map { record in
                let platform: DevicePlatform
                switch record.platformRaw.lowercased() {
                case "macos": platform = .macOS
                case "android": platform = .android
                case "ios": platform = .iOS
                case "windows": platform = .windows
                case "linux": platform = .linux
                default: platform = .android
                }
                return NearsideDevice(
                    id: record.identity,
                    name: record.name,
                    platform: platform,
                    fingerprint: record.identity,
                    ipAddress: record.lastKnownIp,
                    port: record.lastKnownPort,
                    reachability: .online,
                    lastSeen: record.enrolledAt
                )
            }
        } else {
            self.pairedDevices = []
        }
    }

    private func stageAttachmentsAndPresent() {
        let stageDir = FileManager.default.temporaryDirectory.appendingPathComponent("nearside_share_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: stageDir, withIntermediateDirectories: true)
        self.stagingDirectory = stageDir

        var collectedURLs: [URL] = []
        let group = DispatchGroup()

        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            presentPicker(with: [])
            return
        }

        for item in items {
            guard let attachments = item.attachments else { continue }
            for provider in attachments {
                group.enter()

                if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                        defer { group.leave() }
                        if let url = item as? URL {
                            let dest = stageDir.appendingPathComponent(url.lastPathComponent)
                            try? FileManager.default.copyItem(at: url, to: dest)
                            collectedURLs.append(dest)
                        }
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.image.identifier, options: nil) { item, error in
                        defer { group.leave() }
                        if let url = item as? URL {
                            let dest = stageDir.appendingPathComponent(url.lastPathComponent)
                            try? FileManager.default.copyItem(at: url, to: dest)
                            collectedURLs.append(dest)
                        } else if let image = item as? UIImage, let data = image.jpegData(compressionQuality: 0.95) {
                            let dest = stageDir.appendingPathComponent("Shared_Photo_\(UUID().uuidString.prefix(6)).jpg")
                            try? data.write(to: dest)
                            collectedURLs.append(dest)
                        }
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, error in
                        defer { group.leave() }
                        if let url = item as? URL {
                            let dest = stageDir.appendingPathComponent("link.url")
                            try? url.absoluteString.write(to: dest, atomically: true, encoding: .utf8)
                            collectedURLs.append(dest)
                        }
                    }
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, error in
                        defer { group.leave() }
                        if let text = item as? String {
                            let isURL = text.hasPrefix("http://") || text.hasPrefix("https://")
                            let dest = stageDir.appendingPathComponent(isURL ? "link.url" : "clipboard.txt")
                            try? text.write(to: dest, atomically: true, encoding: .utf8)
                            collectedURLs.append(dest)
                        }
                    }
                } else {
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            if collectedURLs.isEmpty {
                // Fallback test item if provider contained raw text or simulated item
                let fallback = stageDir.appendingPathComponent("Shared_Content.txt")
                try? "Nearside Shared Content".write(to: fallback, atomically: true, encoding: .utf8)
                collectedURLs.append(fallback)
            }
            self.stagedFiles = collectedURLs
            self.presentPicker(with: collectedURLs)
        }
    }

    private func presentPicker(with files: [URL]) {
        let picker = IOSShareRecipientPickerView(
            stagedFiles: files,
            devices: self.pairedDevices,
            onSelectRecipient: { [weak self] device in
                self?.completeHandoff(to: device)
            },
            onCancel: { [weak self] in
                self?.cancelHandoff()
            }
        )

        let hostingVC = UIHostingController(rootView: picker)
        hostingVC.view.translatesAutoresizingMaskIntoConstraints = false
        addChild(hostingVC)
        view.addSubview(hostingVC.view)

        NSLayoutConstraint.activate([
            hostingVC.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingVC.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingVC.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            hostingVC.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        hostingVC.didMove(toParent: self)
    }

    private func completeHandoff(to device: NearsideDevice) {
        cleanupStaging()
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }

    private func cancelHandoff() {
        cleanupStaging()
        let error = NSError(domain: "com.nearside.ios.share", code: -1, userInfo: [NSLocalizedDescriptionKey: "User cancelled transfer."])
        extensionContext?.cancelRequest(withError: error)
    }

    private func cleanupStaging() {
        if let dir = stagingDirectory {
            try? FileManager.default.removeItem(at: dir)
            stagingDirectory = nil
        }
    }
}

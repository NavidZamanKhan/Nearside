import AppKit
import SwiftUI
import UniformTypeIdentifiers

@objc(ShareViewController)
public final class ShareViewController: NSViewController {

    private var hostingController: NSHostingController<ShareRecipientPickerView>?

    public override func loadView() {
        self.view = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 220))
    }

    public override func viewDidLoad() {
        super.viewDidLoad()

        let itemCount = extensionContext?.inputItems.count ?? 1

        let knownDevices = [
            NearsideDevice(
                id: "ns1_0859d384629f7bb1e9a809502e693103c865c1b411ae565eb053a97b3b43d888",
                name: "iQOO Neo9",
                platform: .android,
                fingerprint: "ns1_0859d384629f7bb1e9a809502e693103c865c1b411ae565eb053a97b3b43d888",
                ipAddress: "192.168.0.100",
                port: 41433,
                reachability: .online,
                lastSeen: Date()
            )
        ]

        let pickerView = ShareRecipientPickerView(
            itemCount: itemCount,
            devices: knownDevices,
            onSelectDevice: { [weak self] _ in
                self?.completeShare()
            },
            onCancel: { [weak self] in
                self?.cancelShare()
            }
        )

        let hosting = NSHostingController(rootView: pickerView)
        self.hostingController = hosting
        addChild(hosting)
        hosting.view.frame = self.view.bounds
        hosting.view.autoresizingMask = [.width, .height]
        self.view.addSubview(hosting.view)
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

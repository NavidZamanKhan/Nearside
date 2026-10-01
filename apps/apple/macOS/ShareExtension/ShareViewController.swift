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
                id: "dev_iqoo_neo9",
                name: "iQOO Neo9",
                platform: .android,
                fingerprint: "ns1_8b31f0e2a45c7198bb4d1938fe76d029",
                ipAddress: "192.168.0.101",
                port: 41433,
                reachability: .online,
                lastSeen: Date()
            ),
            NearsideDevice(
                id: "dev_ipad_pro",
                name: "iPad Air",
                platform: .iOS,
                fingerprint: "ns1_c5e891b00142fa9166da23491f08cb34",
                ipAddress: "192.168.0.108",
                port: 41433,
                reachability: .unreachable,
                lastSeen: Date().addingTimeInterval(-86400 * 2)
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

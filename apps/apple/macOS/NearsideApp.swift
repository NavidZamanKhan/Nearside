import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var identityAvailable = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        do {
            _ = try DeviceIdentity.loadOrCreatePersistent()
            identityAvailable = true
        }
        catch {
            let failure = (error as? NearsideError) ?? NearsideError(code: .trustStorageFailed,
                operation: "loadDeviceIdentity", message: "Persistent device identity is unavailable.")
            NearsideLogger.shared.error(failure, state: "failed")
            let alert = NSAlert()
            alert.messageText = "Nearside cannot access its device identity"
            alert.informativeText = failure.localizedDescription
            alert.runModal()
            NSApplication.shared.terminate(nil)
            return
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard identityAvailable else { return }
        MacNotificationManager.shared.setup()
        StatusItemController.shared.setup()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard identityAvailable else { return }
        Task { @MainActor in
            for url in urls where url.pathExtension == "nearshare" {
                HostShareController.open(requestURL: url)
            }
        }
    }
}

@main
struct NearsideMain {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
}

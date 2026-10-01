import Cocoa

@main
class AppDelegate: NSObject, NSApplicationDelegate {

    private var window: NSWindow!
    private var coordinator: StagingCoordinator!
    private var resident: ResidentReceiverSimulator!
    private var statusLabel: NSTextField!

    func applicationDidFinishLaunching(_ notification: Notification) {
        coordinator = StagingCoordinator()
        resident = ResidentReceiverSimulator(coordinator: coordinator)
        resident.start()

        let rect = NSRect(x: 100, y: 100, width: 400, height: 260)
        window = NSWindow(contentRect: rect, styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Nearside E2 Host Application"
        window.center()

        let contentView = NSView(frame: rect)
        contentView.wantsLayer = true

        let title = NSTextField(labelWithString: "Nearside E2 Share Probe")
        title.font = NSFont.systemFont(ofSize: 18, weight: .bold)
        title.frame = NSRect(x: 20, y: 210, width: 360, height: 26)
        contentView.addSubview(title)

        statusLabel = NSTextField(labelWithString: "Resident receiver mock is RUNNING.\nMonitoring staging directory for incoming Share jobs...")
        statusLabel.font = NSFont.systemFont(ofSize: 13)
        statusLabel.textColor = NSColor.secondaryLabelColor
        statusLabel.frame = NSRect(x: 20, y: 130, width: 360, height: 60)
        contentView.addSubview(statusLabel)

        let pollButton = NSButton(title: "Process Staged Jobs Now", target: self, action: #selector(pollJobs))
        pollButton.bezelStyle = .rounded
        pollButton.frame = NSRect(x: 20, y: 70, width: 200, height: 32)
        contentView.addSubview(pollButton)

        window.contentView = contentView
        window.makeKeyAndOrderFront(nil)

        // Poll periodically
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.pollJobs()
        }
    }

    @objc private func pollJobs() {
        do {
            let acks = try resident.processPendingJobs()
            if !acks.isEmpty {
                for ack in acks {
                    statusLabel.stringValue = "Claimed & Verified Job \(ack.jobId)!\nItems: \(ack.verifiedItems), Bytes: \(ack.totalVerifiedBytes)"
                }
            }
        } catch {
            statusLabel.stringValue = "Error processing jobs: \(error.localizedDescription)"
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
}

import AppKit
import SwiftUI

@MainActor
public final class StatusItemController: NSObject {
    public static let shared = StatusItemController()

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var preferencesWindow: NSWindow?

    public override init() {
        super.init()
    }

    public func setup() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "arrow.left.arrow.right.circle", accessibilityDescription: "Nearside")
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        self.statusItem = item

        let pop = NSPopover()
        pop.contentSize = NSSize(width: 350, height: 420)
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(
            rootView: MenuBarShelfView(
                appState: AppState.shared,
                onOpenSettings: { [weak self] in
                    self?.openPreferences()
                },
                onQuit: {
                    NSApplication.shared.terminate(nil)
                }
            )
        )
        self.popover = pop
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard let popover = self.popover, let button = statusItem?.button else { return }

        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    public func openPreferences() {
        popover?.performClose(nil)

        if let existing = preferencesWindow {
            existing.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.center()
        window.title = "Nearside Preferences"
        window.contentViewController = NSHostingController(
            rootView: PreferencesView(appState: AppState.shared)
        )
        window.isReleasedWhenClosed = false
        self.preferencesWindow = window

        window.makeKeyAndOrderFront(nil)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}

import Foundation
import AppKit
import UserNotifications

@MainActor
public final class MacNotificationManager: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = MacNotificationManager()

    public static let categoryFileReceived = "NEARSIDE_FILE_RECEIVED"
    public static let categoryContentReceived = "NEARSIDE_CONTENT_RECEIVED"

    public static let actionShowInFinder = "ACTION_SHOW_IN_FINDER"
    public static let actionOpenFile = "ACTION_OPEN_FILE"
    public static let actionOpenURL = "ACTION_OPEN_URL"
    public static let actionCopyText = "ACTION_COPY_TEXT"

    private override init() {
        super.init()
    }

    public func setup() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self

        // Define Actions
        let showInFinderAction = UNNotificationAction(
            identifier: Self.actionShowInFinder,
            title: "Show in Finder",
            options: [.foreground]
        )
        let openFileAction = UNNotificationAction(
            identifier: Self.actionOpenFile,
            title: "Open",
            options: [.foreground]
        )
        let openUrlAction = UNNotificationAction(
            identifier: Self.actionOpenURL,
            title: "Open in Browser",
            options: [.foreground]
        )
        let copyTextAction = UNNotificationAction(
            identifier: Self.actionCopyText,
            title: "Copy",
            options: []
        )

        // Define Categories
        let fileCategory = UNNotificationCategory(
            identifier: Self.categoryFileReceived,
            actions: [showInFinderAction, openFileAction],
            intentIdentifiers: [],
            options: []
        )
        let contentCategory = UNNotificationCategory(
            identifier: Self.categoryContentReceived,
            actions: [openUrlAction, copyTextAction],
            intentIdentifiers: [],
            options: []
        )

        center.setNotificationCategories([fileCategory, contentCategory])

        center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if granted {
                NearsideLogger.shared.info("notifications", "setup", "User notifications authorized", state: "active")
            } else if let error = error {
                NearsideLogger.shared.warn("notifications", "setup", "User notification authorization error", underlyingError: error)
            }
        }
    }

    public func notifyTransferComplete(record: TransferRecord, downloadsURL: URL) {
        guard record.direction == .incoming else { return }

        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.sound = .default

        if record.payloadType == .url, let text = record.payloadText {
            content.title = "Link Received from \(record.deviceName)"
            content.body = text
            content.categoryIdentifier = Self.categoryContentReceived
            content.userInfo = ["urlText": text]
        } else if record.payloadType == .text, let text = record.payloadText {
            content.title = "Text Received from \(record.deviceName)"
            content.body = text.count > 100 ? "\(text.prefix(97))..." : text
            content.categoryIdentifier = Self.categoryContentReceived
            content.userInfo = ["rawText": text]
        } else {
            let fileURL = downloadsURL.appendingPathComponent(record.filename)
            content.title = "File Received from \(record.deviceName)"
            content.body = "\(record.filename) (\(record.formattedSize))"
            content.categoryIdentifier = Self.categoryFileReceived
            content.userInfo = ["filePath": fileURL.path]
        }

        let request = UNNotificationRequest(
            identifier: "nearside_recv_\(record.id)",
            content: content,
            trigger: nil
        )

        center.add(request) { error in
            if let error = error {
                NearsideLogger.shared.warn("notifications", "post", "Failed to schedule notification", underlyingError: error)
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate
    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let action = response.actionIdentifier

        Task { @MainActor in
            if action == Self.actionOpenFile || action == UNNotificationDefaultActionIdentifier {
                if let path = userInfo["filePath"] as? String {
                    let url = URL(fileURLWithPath: path)
                    if action == Self.actionOpenFile {
                        NSWorkspace.shared.open(url)
                    } else {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } else if let urlText = userInfo["urlText"] as? String, let url = URL(string: urlText) {
                    NSWorkspace.shared.open(url)
                }
            } else if action == Self.actionShowInFinder {
                if let path = userInfo["filePath"] as? String {
                    let url = URL(fileURLWithPath: path)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            } else if action == Self.actionOpenURL {
                if let urlText = userInfo["urlText"] as? String, let url = URL(string: urlText) {
                    NSWorkspace.shared.open(url)
                }
            } else if action == Self.actionCopyText {
                let copyText = (userInfo["urlText"] as? String) ?? (userInfo["rawText"] as? String)
                if let text = copyText {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            completionHandler()
        }
    }

    public nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}

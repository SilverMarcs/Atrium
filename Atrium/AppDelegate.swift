import AppKit
import UserNotifications

extension Notification.Name {
    static let navigateToChat = Notification.Name("navigateToChat")
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        NSApp.dockTile.badgeLabel = nil
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let workspaceID = userInfo["workspaceID"] as? String,
           let chatID = userInfo["chatID"] as? String {
            NSApplication.shared.activate(ignoringOtherApps: true)
            NotificationCenter.default.post(
                name: .navigateToChat,
                object: nil,
                userInfo: ["workspaceID": workspaceID, "chatID": chatID]
            )
        }
        completionHandler()
    }

    static func sendChatNotification(workspaceTitle: String, body: String, workspaceID: UUID, chatID: UUID) {
        DispatchQueue.main.async {
            let content = UNMutableNotificationContent()
            content.title = workspaceTitle
            content.body = body
            content.sound = .default
            content.userInfo = [
                "workspaceID": workspaceID.uuidString,
                "chatID": chatID.uuidString,
            ]
            let request = UNNotificationRequest(
                identifier: chatID.uuidString,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request)

            if !NSApp.isActive {
                NSApp.dockTile.badgeLabel = ""
                NSApp.requestUserAttention(.criticalRequest)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Only confirm if there's something the user might lose: running
        // commands or connected chat sessions. Otherwise quit silently.
        guard let store = WorkspaceStore.shared, store.hasLiveWork else {
            return .terminateNow
        }

        let alert = NSAlert()
        alert.messageText = "Quit Atrium?"
        alert.informativeText = "There are running commands or active sessions. Quitting will stop them."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Belt-and-braces: even if `applicationShouldTerminate` was bypassed
        // (sleep, system shutdown, etc.) make sure no child process outlives
        // us as an orphan reparented to launchd.
        WorkspaceStore.shared?.killAllRunningCommands()
    }
}

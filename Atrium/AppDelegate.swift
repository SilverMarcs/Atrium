import AppKit
import UserNotifications

extension Notification.Name {
    static let navigateToSession = Notification.Name("navigateToSession")
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppDelegate.clearBadge()
    }

    // Show notifications even when the app is in the foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // Handle notification click — navigate to the workspace/terminal that triggered it
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let threadID = userInfo["threadID"] as? String {
            NotificationCenter.default.post(
                name: .navigateToSession,
                object: nil,
                userInfo: ["threadID": threadID]
            )
        } else if let workspaceID = userInfo["workspaceID"] as? String,
           let terminalID = userInfo["terminalID"] as? String {
            NotificationCenter.default.post(
                name: .navigateToSession,
                object: nil,
                userInfo: [
                    "workspaceID": workspaceID,
                    "terminalID": terminalID,
                ]
            )
        }
        AppDelegate.clearBadge()
        completionHandler()
    }

    static func sendNotification(workspaceID: UUID, terminalID: UUID, workspaceName: String? = nil, terminalName: String? = nil) {
        let content = UNMutableNotificationContent()
        content.title = workspaceName ?? "Terminal"
        content.body = terminalName ?? "Terminal needs attention"
        content.sound = .default
        content.userInfo = [
            "terminalID": terminalID.uuidString,
            "workspaceID": workspaceID.uuidString,
        ]

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    static func sendThreadNotification(_ thread: AgentThread, projectIconURL: URL? = nil) {
        guard NotificationRouting.shared.shouldNotifyMac(taskID: thread.id) else { return }
        let content = UNMutableNotificationContent()
        content.title = thread.title
        content.body = "\(thread.title) — \(thread.status == .waiting ? "Needs your input" : "Done")"
        content.sound = .default
        content.userInfo = ["threadID": thread.id]
        let icon = ProjectNotificationIcon.pngData(at: projectIconURL)
        Task { @MainActor in
            let notification: UNNotificationContent
            if let icon,
               let updated = try? await ProjectNotificationContent.updating(
                content: content, title: thread.title, imageData: icon, conversationID: thread.id
               ) {
                notification = updated
            } else {
                notification = content
            }
            guard NotificationRouting.shared.shouldNotifyMac(taskID: thread.id) else { return }
            let request = UNNotificationRequest(identifier: "thread:\(thread.id)", content: notification, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
            bounceDockIcon()
            if !NSApplication.shared.isActive { showBadge() }
        }
    }

    static func bounceDockIcon() {
        NSApplication.shared.requestUserAttention(.criticalRequest)
    }

    static func showBadge() {
        NSApplication.shared.dockTile.badgeLabel = " "
    }

    static func clearBadge() {
        NSApplication.shared.dockTile.badgeLabel = nil
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        #if DEBUG
        return .terminateNow
        #else
        let alert = NSAlert()
        alert.messageText = "Quit Atrium?"
        alert.informativeText = "Are you sure you want to quit?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        return response == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
        #endif
    }
}

import AppKit
import AtriumClient
import AtriumProtocol
import UserNotifications

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
        NotificationRouting.shared.cameToFront(device: nil)
    }

    // Show notifications even when the app is in the foreground
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    // Opens the task or command that raised the notification, on this Mac's own host.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        if let app = AppModel.shared, let localHost = app.localHost {
            if let threadID = userInfo["threadID"] as? String {
                app.selection = TaskRef(hostID: localHost.id, taskID: threadID)
            } else if let workspaceID = (userInfo["workspaceID"] as? String).flatMap(UUID.init(uuidString:)),
                      let commandID = (userInfo["commandID"] as? String).flatMap(UUID.init(uuidString:)),
                      let project = app.project(WorkspaceRef(hostID: localHost.id, workspaceID: workspaceID)) {
                app.showingInspector = true
                project.selectedTab = .commands
                project.selectedCommandID = commandID
            }
        }
        AppDelegate.clearBadge()
        completionHandler()
    }

    /// Tells the user a saved command asked for attention by ringing the bell.
    static func sendNotification(workspaceID: UUID, commandID: UUID, workspaceName: String, commandName: String) {
        let content = UNMutableNotificationContent()
        content.title = workspaceName
        content.body = "\(commandName) needs attention"
        content.sound = .default
        content.userInfo = [
            "commandID": commandID.uuidString,
            "workspaceID": workspaceID.uuidString,
        ]

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// Alerts about a task under its project's name, which a task relocated
    /// into a linked worktree keeps, rather than the worktree folder's.
    static func sendThreadNotification(_ thread: AgentThread, workspace: Workspace?) {
        guard NotificationRouting.shared.shouldNotifyMac(taskID: thread.id) else { return }
        let projectName = workspace?.name ?? thread.projectName
        let content = UNMutableNotificationContent()
        content.title = projectName
        content.subtitle = thread.title
        content.body = thread.status == .waiting ? "Needs your input" : "Done"
        content.sound = .default
        content.userInfo = ["threadID": thread.id]
        let icon = ProjectNotificationIcon.pngData(at: workspace?.customIconURL)
        Task { @MainActor in
            let notification: UNNotificationContent
            if let icon,
               let updated = try? await ProjectNotificationContent.updating(
                content: content, title: projectName, imageData: icon, conversationID: thread.id
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

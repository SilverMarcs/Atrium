import AppKit
import AtriumClient
import AtriumHost
import AtriumProtocol
import UserNotifications

/// Launch, quit, and this Mac's alerts: the host decides when to alert, and
/// this shows the alerts and opens what they're about when clicked.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, MacAlerts {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        Self.raiseOpenFileLimit()
        NotificationRouting.shared.mac = self
    }

    /// Lifts launchd's default of 256 open files: the host's connections,
    /// file watchers and Git processes' pipes together can need more.
    private static func raiseOpenFileLimit() {
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let target = min(limit.rlim_max, rlim_t(OPEN_MAX))
        guard limit.rlim_cur < target else { return }
        limit.rlim_cur = target
        setrlimit(RLIMIT_NOFILE, &limit)
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
                app.showInspector(.commands, in: project)
                project.selectedCommand = .command(commandID)
            }
        }
        clearBadge()
        completionHandler()
    }

    // MARK: - MacAlerts

    func alert(commandID: UUID, commandName: String, workspaceID: UUID?, workspaceName: String?) {
        bounceDockIcon()
        if !NSApplication.shared.isActive { showBadge() }
        guard let workspaceID, let workspaceName else { return }
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

    func alert(taskID: String, title: String, projectName: String, needsInput: Bool, projectIcon: Data?) {
        let content = UNMutableNotificationContent()
        content.title = projectName
        content.subtitle = title
        content.body = needsInput ? "Needs your input" : "Done"
        content.sound = .default
        content.userInfo = ["threadID": taskID]
        Task { @MainActor in
            let notification: UNNotificationContent
            if let projectIcon,
               let updated = try? await ProjectNotificationContent.updating(
                content: content, title: projectName, imageData: projectIcon, conversationID: taskID
               ) {
                notification = updated
            } else {
                notification = content
            }
            // Atrium may have come to the front while the avatar was made.
            guard NotificationRouting.shared.shouldNotifyMac(taskID: taskID) else { return }
            let request = UNNotificationRequest(identifier: "thread:\(taskID)", content: notification, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
            bounceDockIcon()
            if !NSApplication.shared.isActive { showBadge() }
        }
    }

    func clearAlerts() {
        DeliveredNotifications.clearAll()
        clearBadge()
    }

    private func bounceDockIcon() {
        NSApplication.shared.requestUserAttention(.criticalRequest)
    }

    private func showBadge() {
        NSApplication.shared.dockTile.badgeLabel = " "
    }

    private func clearBadge() {
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

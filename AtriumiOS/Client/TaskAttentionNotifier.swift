import Foundation
import UserNotifications

/// Posts a local notification when a task finishes or needs input, mirroring
/// the Mac's alerts while the companion is running.
@MainActor
final class TaskAttentionNotifier {
    private var hasRequestedAuthorization = false

    func requestAuthorization() {
        guard !hasRequestedAuthorization else { return }
        hasRequestedAuthorization = true
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) }
    }

    /// Only an observed transition notifies; a first snapshot just sets the baseline.
    func notify(from old: WireTasksSnapshot?, to new: WireTasksSnapshot) {
        guard let old else { return }
        let previous = Dictionary(old.tasks.map { ($0.id, $0.status) }, uniquingKeysWith: { $1 })
        for task in new.tasks where !task.isSettled && !task.isSnoozed {
            guard let before = previous[task.id], before != task.status, before != .unknown,
                  task.status == .done || task.status == .waiting else { continue }
            post(task)
        }
    }

    private func post(_ task: WireTask) {
        let content = UNMutableNotificationContent()
        content.title = task.projectName
        content.body = "\(task.title) — \(task.status == .waiting ? "Needs your input" : "Done")"
        content.sound = .default
        content.userInfo = ["taskID": task.id]
        let request = UNNotificationRequest(identifier: "task:\(task.id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

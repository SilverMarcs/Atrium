import AtriumProtocol
import Foundation

/// An overlay on host state, discarded when its request succeeds or fails.
/// Incoming deltas still update the underlying snapshot while it is pending.
struct OptimisticTaskUpdate: Identifiable {
    let id = UUID()
    let taskID: String
    let action: TaskAction
    let date = Date.now

    init?(_ request: HostRequest) {
        switch request {
        case .task(let taskID, let action):
            if case .fork = action { return nil }
            if case .startSideChat = action { return nil }
            if case .respond = action { return nil }
            if case .rewind = action { return nil }
            self.taskID = taskID
            self.action = action
        case .prompt(let taskID, _, _):
            self.taskID = taskID
            self.action = .unsnooze
        default:
            return nil
        }
    }

    func apply(to snapshot: inout WireTasksSnapshot) {
        guard let index = snapshot.tasks.firstIndex(where: { $0.id == taskID }) else { return }
        // Prevent another menu action on this row until the host acknowledges it.
        snapshot.tasks[index].actions.formIntersection([.prompt, .interrupt])
        switch action {
        case .settle:
            snapshot.tasks[index].isSettled = true
            snapshot.tasks[index].snoozedUntil = nil
        case .restore:
            snapshot.tasks[index].isSettled = false
        case .snooze(let until):
            snapshot.tasks[index].snoozedUntil = until
        case .unsnooze:
            snapshot.tasks[index].isSettled = false
            snapshot.tasks[index].snoozedUntil = nil
            snapshot.tasks[index].updatedAt = date
        case .viewed, .markRead:
            snapshot.tasks[index].hasUnreadResult = false
        case .markUnread:
            snapshot.tasks[index].hasUnreadResult = true
        case .rename(let title):
            snapshot.tasks[index].title = title
        case .selectModel(let model, let reasoningEffort):
            snapshot.tasks[index].model = model
            if let reasoningEffort { snapshot.tasks[index].reasoningEffort = reasoningEffort }
        case .setFastMode(let isOn):
            snapshot.tasks[index].isFastMode = isOn
        case .delete:
            snapshot.tasks.remove(at: index)
        case .fork, .startSideChat, .respond, .rewind:
            break
        }
    }
}

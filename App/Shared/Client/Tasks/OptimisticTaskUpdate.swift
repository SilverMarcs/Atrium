import AtriumProtocol
import Foundation

/// An overlay on host state, discarded when its request succeeds or fails.
/// Incoming deltas still update the underlying snapshot while it is pending.
struct OptimisticTaskUpdate: Identifiable {
    let id = UUID()
    let taskID: String
    let action: TaskAction
    /// A prompt queued to wait for the agent's turn to end.
    private var queued: QueuedPrompt?
    let date = Date.now

    init?(_ request: HostRequest) {
        switch request {
        case .task(let taskID, let action):
            if case .fork = action { return nil }
            if case .startSideChat = action { return nil }
            if case .respond = action { return nil }
            if case .rewind = action { return nil }
            if case .openTerminal = action { return nil }
            self.taskID = taskID
            self.action = action
        case .prompt(let taskID, let text, let images, let queue):
            self.taskID = taskID
            self.action = .unsnooze
            queued = queue.map { QueuedPrompt(id: $0, text: text, images: images) }
        default:
            return nil
        }
    }

    /// Applies only the action's own effect. The allowed actions stay as the host
    /// sent them, as the host withholds them itself while a change is under way.
    func apply(to snapshot: inout WireTasksSnapshot) {
        guard let index = snapshot.tasks.firstIndex(where: { $0.id == taskID }) else { return }
        // A first queued prompt shows waiting at once. One joining it shows
        // once the host has added it, which this can't tell from its text.
        if let queued, snapshot.tasks[index].queuedPrompt == nil {
            snapshot.tasks[index].queuedPrompt = queued
        }
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
        case .setPermissionMode(let mode):
            snapshot.tasks[index].permissionMode = mode
        case .delete:
            snapshot.tasks.remove(at: index)
        case .takeQueuedPrompt:
            snapshot.tasks[index].queuedPrompt = nil
        case .fork, .startSideChat, .respond, .rewind, .openTerminal:
            break
        }
    }
}

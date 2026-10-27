import Synchronization
import UserNotifications

/// The system's expiry callback can race with the network and donation tasks.
// The original content is immutable; mutable delivery state is protected by the mutex.
nonisolated final class NotificationDelivery: @unchecked Sendable {
    private struct State: @unchecked Sendable {
        var handler: ((UNNotificationContent) -> Void)?
        var task: Task<Void, Never>?
    }

    let original: UNNotificationContent
    private let state: Mutex<State>

    init(original: UNNotificationContent, handler: @escaping (UNNotificationContent) -> Void) {
        self.original = original
        state = Mutex(State(handler: handler))
    }

    func setTask(_ task: Task<Void, Never>) {
        let finished = state.withLock { value in
            guard value.handler != nil else { return true }
            value.task = task
            return false
        }
        if finished { task.cancel() }
    }

    func finish(with content: UNNotificationContent? = nil) {
        let pending = state.withLock { value in
            let pending = value
            value.handler = nil
            value.task = nil
            return pending
        }
        pending.task?.cancel()
        pending.handler?(content ?? original)
    }
}

import Foundation
import ACP

extension ACPSession {
    func listenForNotifications(client: Client) {
        notificationTask?.cancel()
        notificationTask = Task {
            let decoder = JSONDecoder()
            let encoder = JSONEncoder()

            for await notification in await client.notifications {
                guard !Task.isCancelled else { break }

                guard notification.method == "session/update",
                      let params = notification.params else { continue }

                do {
                    let data = try encoder.encode(params)
                    let update = try decoder.decode(SessionUpdateNotification.self, from: data)
                    handleUpdate(update.update)
                } catch {
                    // Skip unparseable notifications
                }
            }
        }
    }

    @MainActor
    private func handleUpdate(_ update: SessionUpdate) {
        if isReplaying {
            // During replay, only allow session metadata updates through —
            // message content and plan state are already persisted locally.
            switch update {
            case .availableCommandsUpdate, .configOptionUpdate, .usageUpdate,
                 .sessionInfoUpdate, .currentModeUpdate, .plan:
                break
            default:
                return
            }
        }
        onSessionUpdate?(update)
    }
}

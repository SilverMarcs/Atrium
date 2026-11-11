import UserNotifications
import Synchronization

final class NotificationService: UNNotificationServiceExtension, @unchecked Sendable {
    private let delivery = Mutex<NotificationDelivery?>(nil)

    override func didReceive(
        _ request: UNNotificationRequest,
        withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
    ) {
        let current = NotificationDelivery(original: request.content, handler: contentHandler)
        let previous = delivery.withLock { value in
            let previous = value
            value = current
            return previous
        }
        previous?.finish()

        let info = request.content.userInfo
        guard let hostID = info["hostID"] as? String,
              let taskID = info["taskID"] as? String, !taskID.isEmpty, taskID.count <= 256,
              let urlString = info["projectIconURL"] as? String,
              let url = RelayIconDownloader.trustedURL(urlString, hostID: hostID) else {
            current.finish()
            return
        }

        let task = Task {
            do {
                let imageData = try await RelayIconDownloader.download(from: url)
                try Task.checkCancellation()
                let updated = try await ProjectNotificationContent.updating(
                    content: current.original,
                    title: current.original.title,
                    imageData: imageData,
                    conversationID: "\(hostID):\(taskID)"
                )
                current.finish(with: updated)
            } catch {
                current.finish()
            }
        }
        current.setTask(task)
    }

    override func serviceExtensionTimeWillExpire() {
        delivery.withLock { $0 }?.finish()
    }
}

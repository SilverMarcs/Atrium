import Foundation
import Observation

/// An edit is local until submission; cancellation never touches provider history or the composer.
@MainActor
@Observable
final class ConversationMessageEdit: Identifiable {
    let id = UUID()
    let host: HostClient
    let taskID: String
    let messageID: String
    let target: String
    let images: [Data]
    var text: String
    var addedImages: [ComposerImage] = []
    private(set) var isSubmitting = false
    private(set) var errorMessage: String?

    init?(message: TranscriptMessage, item: HostTask) {
        guard let target = message.editTarget else { return nil }
        host = item.host
        taskID = item.task.id
        messageID = message.id
        self.target = target
        images = message.images ?? []
        text = message.blocks.compactMap(\.text).joined(separator: "\n")
    }

    var canSubmit: Bool {
        !isSubmitting && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty || !addedImages.isEmpty)
            && host.task(taskID)?.actions.contains(.editMessage) == true
            && host.conversations.pendingPrompts[taskID]?.isEmpty != false
    }

    func submit(send: (String, [Data]) -> Void) async -> Bool {
        guard canSubmit else { return false }
        isSubmitting = true
        errorMessage = nil
        let replacementText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let replacementImages = addedImages.map(\.data)
        defer { isSubmitting = false }
        do {
            guard case .rewound(let messages, let originalImages) = try await host.request(
                .task(id: taskID, action: .rewind(messageID: target))
            ) else { throw HostClientError.unexpectedReply }
            host.conversations.transcripts[taskID] = messages
            host.conversations.reconcile(taskID: taskID)
            send(replacementText, originalImages + replacementImages)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

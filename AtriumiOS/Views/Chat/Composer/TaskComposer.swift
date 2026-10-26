import Foundation

/// A task's prompt draft with its attached images, and whether the
/// search-field composer has focus.
@MainActor
@Observable
final class TaskComposer {
    var draft = ""
    private(set) var images: [ComposerImage] = []
    var isPickingPhotos = false
    var isTakingPhoto = false
    /// Mirrors the composer's focus, where the timeline observes it to scroll
    /// to the latest message (`FocusState` is view-local).
    var isFocused = false

    static let maxImages = 4

    var remainingImageSlots: Int { max(Self.maxImages - images.count, 0) }

    /// Whether there's a prompt or an image to send.
    var hasContent: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty
    }

    /// Attaches images from the photo library or camera, up to `maxImages`.
    func attach(_ sources: [Data]) async {
        for source in sources.prefix(remainingImageSlots) {
            guard let image = await ComposerImage.prepare(source), remainingImageSlots > 0 else { continue }
            images.append(image)
        }
    }

    func remove(_ image: ComposerImage) {
        images.removeAll { $0.id == image.id }
    }

    /// Sends the draft and its images to the task's agent, or explains why it
    /// can't take a prompt right now. The draft is kept when nothing is sent.
    /// - Returns: Whether the prompt was sent.
    @discardableResult
    func submit(to task: WireTask, using client: CompanionClient) -> Bool {
        guard hasContent else { return false }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard task.actions.contains(.prompt) else {
            client.actionError = task.status == .waiting
                ? "\(task.provider.name) is waiting for an answer. Reply on your host."
                : "\(task.provider.name) can’t take a prompt right now."
            return false
        }
        draft = ""
        client.sendPrompt(text, images: images.map(\.data), to: task.id)
        images = []
        return true
    }
}

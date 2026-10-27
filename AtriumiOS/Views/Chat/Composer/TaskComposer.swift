import Foundation

/// A task's prompt draft with its attached images, and whether the
/// search-field composer has focus.
@MainActor
@Observable
final class TaskComposer {
    let dictation = ComposerDictation()
    var draft = ""
    private(set) var isSubmittingDictation = false
    private(set) var focusRequestID: UUID?
    private(set) var images: [ComposerImage] = []
    var isPickingPhotos = false
    var isTakingPhoto = false
    /// Mirrors the composer's focus, where the timeline observes it to scroll
    /// to the latest message (`FocusState` is view-local).
    var isFocused = false
    /// A prompt just sent from the bottom-bar composer is still moving into
    /// view. The composer keeps its keyboard up until the timeline settles on
    /// it, so the prompt and the working indicator land before the keyboard
    /// starts to hide, rather than in the same frame.
    private(set) var isRevealingSentPrompt = false
    private var revealTimeout: Task<Void, Never>?

    static let maxImages = 4
    /// Ends a reveal the timeline never reports settling, such as one with
    /// nothing to scroll.
    private static let maximumRevealDuration: Duration = .milliseconds(400)

    func appendTranscription(_ text: String) {
        draft += (draft.isEmpty || draft.last?.isWhitespace == true ? "" : " ") + text
        focusRequestID = UUID()
    }

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

    /// Waits for the timeline to bring the prompt just sent into view.
    func beginRevealingSentPrompt() {
        isRevealingSentPrompt = true
        revealTimeout?.cancel()
        revealTimeout = Task { [weak self] in
            try? await Task.sleep(for: Self.maximumRevealDuration)
            guard !Task.isCancelled else { return }
            self?.finishRevealingSentPrompt()
        }
    }

    /// The timeline has settled, with the prompt just sent in view.
    func finishRevealingSentPrompt() {
        revealTimeout?.cancel()
        revealTimeout = nil
        guard isRevealingSentPrompt else { return }
        isRevealingSentPrompt = false
    }

    /// Sends the draft and its images to the task's agent, or explains why it
    /// can't take a prompt right now. The draft is kept when nothing is sent.
    /// - Returns: Whether the prompt was sent.
    @discardableResult
    func submit(to task: WireTask, using client: CompanionClient) -> Bool {
        guard !isSubmittingDictation else { return false }
        if dictation.isActive {
            let session = dictation.sessionID
            isSubmittingDictation = true
            Task {
                defer { isSubmittingDictation = false }
                guard await dictation.finish(session: session), let currentTask = client.task(task.id) else { return }
                _ = sendDraft(to: currentTask, using: client)
            }
            return false
        }
        return sendDraft(to: task, using: client)
    }

    private func sendDraft(to task: WireTask, using client: CompanionClient) -> Bool {
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

import AtriumClient
import AtriumProtocol
import SwiftUI

/// A task's prompt draft with its attached images, its dictation, and any
/// message being edited. The Mac and iOS composers both present one.
@MainActor
@Observable
final class TaskComposer {
    let dictation = ComposerDictation()
    private var ordinaryDraft = ""
    private(set) var messageEdit: ConversationMessageEdit?
    private(set) var editedPromptID: UUID?
    /// Editing uses a separate draft, leaving the ordinary composer untouched.
    var draft: String {
        get { messageEdit?.text ?? ordinaryDraft }
        set {
            if let messageEdit { messageEdit.text = newValue }
            else { ordinaryDraft = newValue }
        }
    }
    private(set) var isSubmittingDictation = false
    /// Changes when a transcript lands in the draft, so the field can take focus.
    private(set) var focusRequestID: UUID?
    private var ordinaryImages: [ComposerImage] = []
    var images: [ComposerImage] {
        get { messageEdit?.addedImages ?? ordinaryImages }
        set {
            if let messageEdit { messageEdit.addedImages = newValue }
            else { ordinaryImages = newValue }
        }
    }

    #if os(iOS)
    @ObservationIgnored lazy var pasteDelegate = ComposerPasteDelegate(composer: self)
    var pasteError: String?
    var isPickingPhotos = false
    var isTakingPhoto = false
    /// Mirrors the composer's focus, where the timeline observes it to scroll
    /// to the latest message (`FocusState` is view-local).
    var isFocused = false

    static let maxImages = 4
    /// As in Relay, context-menu dismissal must finish before it restores keyboard focus.
    static let contextMenuDismissalDelay: Duration = .milliseconds(200)
    #else
    static let maxImages = 10
    #endif

    func beginEditing(_ message: TranscriptMessage, in item: HostTask) {
        guard messageEdit?.isSubmitting != true,
              let edit = ConversationMessageEdit(message: message, item: item) else { return }
        dictation.cancel()
        messageEdit = edit
    }

    func cancelEdit() {
        guard messageEdit?.isSubmitting != true else { return }
        dictation.cancel()
        messageEdit = nil
    }

    /// Starts recording, or stops and appends its transcript to the draft.
    func toggleDictation(using settings: DictationSettings) {
        guard !isSubmittingDictation, settings.isEnabled else { return }
        dictation.toggle(provider: OpenAITranscriber(apiKey: settings.apiKey)) { [weak self] text in
            guard let self else { return }
            draft += (draft.isEmpty || draft.last?.isWhitespace == true ? "" : " ") + text
            focusRequestID = UUID()
        }
    }

    var remainingImageSlots: Int { max(Self.maxImages - images.count - (messageEdit?.images.count ?? 0), 0) }

    /// Whether there's a prompt or an image to send.
    var hasContent: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty || messageEdit?.images.isEmpty == false
    }

    /// Attaches images from the photo library or camera, up to `maxImages`.
    func attach(_ sources: [Data]) async {
        for source in sources.prefix(remainingImageSlots) {
            guard let image = await ComposerImage.prepare(source), remainingImageSlots > 0 else { continue }
            images.append(image)
        }
    }

    func attachPastedImage(_ image: ComposerImage) throws {
        try ComposerPasteContent.checkImageLimit(images.count + (messageEdit?.images.count ?? 0), maximum: Self.maxImages)
        images.append(image)
    }

    /// Adds dropped text to the draft, or a dropped image to its attachments.
    func receive(_ content: ComposerPasteContent) throws {
        switch content {
        case .text(let text):
            draft += text
        case .image(let image):
            try attachPastedImage(image)
        }
    }

    func remove(_ image: ComposerImage) {
        images.removeAll { $0.id == image.id }
    }

    /// Sends the draft and its images to the task's agent, or explains why it
    /// can't take a prompt right now. The draft is kept when nothing is sent.
    /// A recording is transcribed into the draft first; cancellation or a
    /// failed transcription never sends a partial draft.
    /// - Parameters:
    ///   - animator: Flies the sent prompt's bubble in from the composer.
    ///   - sourceFrame: The field the prompt was sent from, which its bubble
    ///     flies in from. Without one, the composer's own field is used.
    /// - Returns: Whether the prompt was sent.
    @discardableResult
    func submit(
        to item: HostTask,
        animator: PromptSendAnimator,
        from sourceFrame: CGRect? = nil
    ) -> Bool {
        guard !isSubmittingDictation else { return false }
        if dictation.isActive {
            let session = dictation.sessionID
            isSubmittingDictation = true
            Task {
                defer { isSubmittingDictation = false }
                guard await dictation.finish(session: session),
                      let current = item.host.displayedTask(item.task.id) else { return }
                _ = sendDraft(to: HostTask(host: item.host, task: current), animator: animator, from: sourceFrame)
            }
            return false
        }
        return sendDraft(to: item, animator: animator, from: sourceFrame)
    }

    private func sendDraft(to item: HostTask, animator: PromptSendAnimator, from sourceFrame: CGRect?) -> Bool {
        if let edit = messageEdit {
            Task {
                _ = await edit.submit { text, images in
                    messageEdit = nil
                    editedPromptID = send(text, images: images, to: item, animator: animator, from: sourceFrame)
                }
            }
            return false
        }
        guard hasContent else { return false }
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let task = item.task
        guard task.actions.contains(.prompt) else {
            item.host.actionError = task.status == .waiting
                ? "\(task.provider.name) is waiting for an answer. Reply on your host."
                : "\(task.provider.name) can’t take a prompt right now."
            return false
        }
        _ = send(text, images: images.map(\.data), to: item, animator: animator, from: sourceFrame)
        draft = ""
        images = []
        return true
    }

    private func send(_ text: String, images: [Data], to item: HostTask, animator: PromptSendAnimator, from sourceFrame: CGRect?) -> UUID {
        let animationSource = sourceFrame ?? animator.sourceFrame?()
        let promptID = item.host.sendPrompt(text, images: images, to: item.task.id)
        animator.begin(promptID, text: text, from: animationSource)
        return promptID
    }
}

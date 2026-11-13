import AtriumClient
import AtriumProtocol
import PhotosUI
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

    /// Why an image or item couldn't be attached, until it's been shown.
    var attachmentError: String?

    #if os(iOS)
    @ObservationIgnored lazy var pasteDelegate = ComposerPasteDelegate(composer: self)
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

    /// Not while an edit is saving, and not the message already being edited,
    /// which would throw away its draft.
    func canBeginEditing(_ messageID: String) -> Bool {
        messageEdit?.isSubmitting != true && messageEdit?.messageID != messageID
    }

    func beginEditing(_ message: TranscriptMessage, in item: HostTask) {
        guard canBeginEditing(message.id),
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

    /// Whether Send stands in for Stop: the agent is working and there's
    /// nothing to send.
    func offersStop(for actions: TaskActions) -> Bool {
        actions.contains(.interrupt) && !hasContent && !dictation.isActive && !isSubmittingDictation
    }

    /// Whether there's something to send, or a recording to transcribe and
    /// send. An agent that can't take a prompt says why when it's sent.
    var canSend: Bool {
        !isSubmittingDictation && messageEdit?.canSubmit != false && (hasContent || dictation.isActive)
    }

    /// Throws when the draft already has as many images as it can take.
    func checkImageSlot() throws {
        guard remainingImageSlots > 0 else { throw ComposerPasteError.imageLimit(Self.maxImages) }
    }

    /// Attaches images picked from the photo library.
    func attach(_ items: [PhotosPickerItem]) async {
        await attachImages(items) { item in
            guard let data = try await item.loadTransferable(type: Data.self) else { return nil }
            return await ComposerImage.prepare(data)
        }
    }

    /// Attaches photos taken with the camera.
    func attach(_ sources: [Data]) async {
        await attachImages(sources) { await ComposerImage.prepare($0) }
    }

    /// Attaches image files.
    func attach(contentsOf urls: [URL]) async {
        await attachImages(urls) { try await ComposerImage.prepare(contentsOf: $0) }
    }

    func attachPastedImage(_ image: ComposerImage) throws {
        try checkImageSlot()
        images.append(image)
    }

    /// Attaches images up to `maxImages`, stopping at the first that can't be
    /// and saying why.
    private func attachImages<Source>(_ sources: [Source], load: (Source) async throws -> ComposerImage?) async {
        do {
            for source in sources {
                try checkImageSlot()
                guard let image = try await load(source) else { throw ComposerPasteError.unreadableImage }
                try attachPastedImage(image)
            }
        } catch {
            attachmentError = error.localizedDescription
        }
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
        animator: any PromptSendAnimating,
        from sourceFrame: CGRect? = nil,
        mode: SendMode = .steer
    ) -> Bool {
        guard !isSubmittingDictation else { return false }
        if dictation.isActive {
            let session = dictation.sessionID
            isSubmittingDictation = true
            Task {
                defer { isSubmittingDictation = false }
                guard await dictation.finish(session: session),
                      let current = item.host.displayedTask(item.task.id) else { return }
                _ = sendDraft(to: HostTask(host: item.host, task: current), animator: animator, from: sourceFrame, mode: mode)
            }
            return false
        }
        return sendDraft(to: item, animator: animator, from: sourceFrame, mode: mode)
    }

    private func sendDraft(to item: HostTask, animator: any PromptSendAnimating, from sourceFrame: CGRect?, mode: SendMode) -> Bool {
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
        if mode == .queue, task.status.isWorking {
            queue(text, images: images, to: item)
        } else {
            _ = send(text, images: images.map(\.data), to: item, animator: animator, from: sourceFrame)
        }
        draft = ""
        images = []
        return true
    }

    /// Has the prompt wait for the agent's turn to end. One the host turns
    /// down comes back to the composer, if it's still empty.
    private func queue(_ text: String, images: [ComposerImage], to item: HostTask) {
        Task {
            do {
                try await item.host.queuePrompt(text, images: images.map(\.data), to: item.task.id)
            } catch {
                if !hasContent {
                    draft = text
                    self.images = images
                }
                item.host.actionError = error.localizedDescription
            }
        }
    }

    /// Takes the task's queued prompt back into the composer to edit, ahead
    /// of anything already drafted. Sending it again queues it again.
    func editQueuedPrompt(of item: HostTask) {
        guard messageEdit?.isSubmitting != true else { return }
        Task {
            do { restore(try await item.host.takeQueuedPrompt(from: item.task.id)) }
            catch { item.host.actionError = error.localizedDescription }
        }
    }

    /// Sends the waiting prompt through the ordinary steering path. A failed
    /// send stays in the timeline with Retry, including its original images.
    func sendQueuedPromptNow(of item: HostTask) {
        Task {
            do {
                let prompt = try await item.host.takeQueuedPrompt(from: item.task.id)
                item.host.sendPrompt(prompt.text, images: prompt.images, to: item.task.id)
            } catch {
                item.host.actionError = error.localizedDescription
            }
        }
    }

    /// Stops the agent's turn. The prompt queued behind it comes back to the
    /// composer rather than starting the next turn.
    func stop(_ item: HostTask) {
        Task {
            do {
                if let queued = try await item.host.interrupt(item.task.id) { restore(queued) }
            } catch {
                item.host.actionError = error.localizedDescription
            }
        }
    }

    /// Puts a prompt taken back from the queue in the ordinary draft, ahead
    /// of anything already there.
    private func restore(_ prompt: (text: String, images: [Data])) {
        if messageEdit?.isSubmitting != true { messageEdit = nil }
        draft = QueuedPrompt.joined(draft, to: prompt.text)
        images = prompt.images.map { ComposerImage(data: $0) } + images
        focusRequestID = UUID()
    }

    private func send(_ text: String, images: [Data], to item: HostTask, animator: any PromptSendAnimating, from sourceFrame: CGRect?) -> UUID {
        let animationSource = sourceFrame ?? animator.sourceFrame?()
        animator.willSend()
        let promptID = item.host.sendPrompt(text, images: images, to: item.task.id)
        animator.begin(promptID, text: text, from: animationSource)
        return promptID
    }
}

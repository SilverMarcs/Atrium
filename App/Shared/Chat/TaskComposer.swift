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

    /// The editor's selection in the draft, as it reports it.
    var selection: NSRange?

    /// The slash name being typed at the caret, while the user is choosing a skill.
    var skillQuery: ComposerSkillQuery? {
        ComposerSkillQuery(draft: draft, selection: selection)
    }

    /// Every skill for a bare /, else those whose names contain what's typed.
    func matchingSkills(in skills: [AgentSkill]) -> [AgentSkill] {
        guard let name = skillQuery?.name else { return [] }
        return skills.filter { name.isEmpty || $0.name.localizedStandardContains(name) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Replaces the slash name being typed with `skill`'s, the caret after it.
    func selectSkill(_ skill: AgentSkill) {
        guard let query = skillQuery else { return }
        let replacement = "/\(skill.name) "
        draft = textEditor?.replace(query.range, with: replacement, in: draft)
            ?? (draft as NSString).replacingCharacters(in: query.range, with: replacement)
    }

    private(set) var isSubmittingDictation = false
    private(set) var isQueueingPrompt = false
    private(set) var feedback: ComposerFeedback?
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

    private var ordinaryQuotes: [ComposerQuote] = []
    /// Passages of the chat quoted with a reply, sent ahead of the draft.
    /// An edit doesn't take them, so they wait in the ordinary draft.
    var quotes: [ComposerQuote] { messageEdit == nil ? ordinaryQuotes : [] }
    /// The quote whose reply is being written or changed in its sheet.
    var editedQuote: ComposerQuote?

    /// Whether quotes or images sit above the composer.
    var hasAttachments: Bool { !quotes.isEmpty || !images.isEmpty }

    /// Starts a quote of `text`, to reply to in its sheet.
    func quote(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, messageEdit == nil else { return }
        editedQuote = ComposerQuote(text: text)
    }

    /// Adds a new quote, or keeps a changed reply.
    func save(_ quote: ComposerQuote) {
        if let index = ordinaryQuotes.firstIndex(where: { $0.id == quote.id }) {
            ordinaryQuotes[index] = quote
        } else {
            ordinaryQuotes.append(quote)
        }
    }

    func remove(_ quote: ComposerQuote) {
        ordinaryQuotes.removeAll { $0.id == quote.id }
    }

    /// Why an image or item couldn't be attached, until it's been shown.
    var attachmentError: String?

    @ObservationIgnored lazy var pasteDelegate = ComposerPasteDelegate(composer: self)
    @ObservationIgnored weak var textEditor: (any ComposerTextInserting)?
    var isPickingPhotos = false
    /// Mirrors the composer's focus, where the timeline observes it to scroll
    /// to the latest message (`FocusState` is view-local).
    var isFocused = false

    #if os(iOS)
    var isTakingPhoto = false

    static let maxImages = 4
    /// As in Relay, context-menu dismissal must finish before it restores keyboard focus.
    static let contextMenuDismissalDelay: Duration = .milliseconds(200)
    #else
    var isImportingFiles = false

    static let maxImages = HostProtocol.maxPromptImages
    /// A Mac menu has closed by the time its action runs.
    static let contextMenuDismissalDelay: Duration = .zero
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

    /// Starts recording, or stops and inserts its transcript at the editor's selection.
    func toggleDictation(using settings: DictationSettings) {
        guard !isSubmittingDictation, settings.isEnabled else { return }
        dictation.toggle(provider: OpenAITranscriber(apiKey: settings.apiKey), feedback: { [weak self] kind in
            self?.provideFeedback(kind)
        }) { [weak self] text in
            guard let self else { return }
            draft = textEditor?.insertDictation(text, in: draft)
                ?? ComposerDictationInsertion(transcript: text, draft: draft, selection: nil).applying(to: draft)
            focusRequestID = UUID()
            provideFeedback(.transcriptReady)
        }
    }

    private func provideFeedback(_ kind: ComposerFeedback.Kind) {
        // Send while recording is one action, with immediate feedback. Its
        // transcription and eventual send must not produce more taps.
        guard !isSubmittingDictation else { return }
        feedback = ComposerFeedback(kind: kind)
    }

    var remainingImageSlots: Int { max(Self.maxImages - images.count - (messageEdit?.images.count ?? 0), 0) }

    /// Whether there's a prompt, a quote or an image to send.
    var hasContent: Bool {
        !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || hasAttachments || messageEdit?.images.isEmpty == false
    }

    /// Whether Send stands in for Stop: the agent is working and there's
    /// nothing to send.
    func offersStop(for actions: TaskActions) -> Bool {
        actions.contains(.interrupt) && !hasContent && !dictation.isActive && !isSubmittingDictation
    }

    /// Busy only while the draft itself isn't ready: a recording being
    /// transcribed, an edit or a queued prompt on its way. A prompt already
    /// sent is the timeline's to show, so Send stays ready for the next.
    func sendState(for item: HostTask?) -> ComposerSendState {
        ComposerSendState(
            isBusy: isSubmittingDictation || messageEdit?.isSubmitting == true || isQueueingPrompt,
            offersStop: item.map { offersStop(for: $0.task.actions) } == true
        )
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
        guard sendState(for: item) != .sending else { return false }
        if dictation.isActive {
            let session = dictation.sessionID
            provideFeedback(.send)
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
        let text = ComposerQuote.prompt(quoting: quotes, draft: draft)
        let task = item.task
        guard task.actions.contains(.prompt) else {
            item.host.actionError = task.status == .waiting
                ? "\(task.provider.name) is waiting for an answer. Reply on your host."
                : "\(task.provider.name) can’t take a prompt right now."
            return false
        }
        if mode == .queue, task.status.isWorking {
            provideFeedback(.send)
            queue(text, images: images, to: item)
        } else {
            _ = send(text, images: images.map(\.data), to: item, animator: animator, from: sourceFrame)
        }
        draft = ""
        images = []
        ordinaryQuotes = []
        return true
    }

    /// Has the prompt wait for the agent's turn to end. One the host turns
    /// down comes back to the composer, if it's still empty.
    private func queue(_ text: String, images: [ComposerImage], to item: HostTask) {
        isQueueingPrompt = true
        Task {
            defer { isQueueingPrompt = false }
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

    /// Sends the waiting prompt through the ordinary steering path. One the
    /// host doesn't take comes back to the composer with its images.
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

    /// Whether there's a draft to put aside in the scratchpad.
    var hasScratchpadContent: Bool { messageEdit == nil && hasContent }

    /// Moves the draft, its quotes and its images into the project's
    /// scratchpad. One the host turns down comes back to the composer, if
    /// it's still empty.
    func addToScratchpad(of item: HostTask) {
        guard hasScratchpadContent, let workspaceID = item.task.workspaceID else { return }
        let (draft, images, quotes) = (draft, images, ordinaryQuotes)
        self.draft = ""
        self.images = []
        ordinaryQuotes = []
        Task {
            do {
                let text = ComposerQuote.prompt(quoting: quotes, draft: draft)
                _ = try await item.host.request(.workspace(id: workspaceID, action: .addToScratchpad(text: text, images: images.map(\.data))))
            } catch {
                if !hasContent { (self.draft, self.images, ordinaryQuotes) = (draft, images, quotes) }
                item.host.actionError = error.localizedDescription
            }
        }
    }

    /// ⌘S: puts the draft aside, or on an empty composer brings back the
    /// newest draft in the scratchpad.
    func addToScratchpadOrRestoreNewest(of item: HostTask) {
        if hasScratchpadContent {
            addToScratchpad(of: item)
        } else if messageEdit == nil, let newest = item.scratchpad.first {
            restore(newest, from: item)
        }
    }

    /// Takes a draft out of the project's scratchpad into the composer, ahead
    /// of anything already drafted.
    func restore(_ draft: ScratchpadDraft, from item: HostTask) {
        guard let workspaceID = item.task.workspaceID else { return }
        Task {
            do { restore(try await item.host.takeScratchpadDraft(draft.id, from: workspaceID)) }
            catch { item.host.actionError = error.localizedDescription }
        }
    }

    /// Stops the agent's turn. The prompt queued behind it comes back to the
    /// composer rather than starting the next turn.
    func stop(_ item: HostTask) {
        provideFeedback(.stop)
        Task {
            do {
                if let queued = try await item.host.interrupt(item.task.id) { restore(queued) }
            } catch {
                item.host.actionError = error.localizedDescription
            }
        }
    }

    /// Puts a prompt taken back from the queue or the scratchpad in the
    /// ordinary draft, ahead of anything already there.
    private func restore(_ prompt: (text: String, images: [Data])) {
        if messageEdit?.isSubmitting != true { messageEdit = nil }
        takeBack(prompt.text, images: prompt.images)
        focusRequestID = UUID()
    }

    /// Puts a prompt that couldn't be sent back in the draft, ahead of
    /// anything typed since, to send again.
    func takeBack(_ text: String, images: [Data]) {
        draft = QueuedPrompt.joined(draft, to: text)
        self.images = images.map { ComposerImage(data: $0) } + self.images
    }

    private func send(_ text: String, images: [Data], to item: HostTask, animator: any PromptSendAnimating, from sourceFrame: CGRect?) -> UUID {
        provideFeedback(.send)
        let animationSource = sourceFrame ?? animator.sourceFrame?()
        animator.willSend()
        let promptID = item.host.sendPrompt(text, images: images, to: item.task.id)
        animator.begin(promptID, text: text, hasImages: !images.isEmpty, from: animationSource)
        return promptID
    }
}

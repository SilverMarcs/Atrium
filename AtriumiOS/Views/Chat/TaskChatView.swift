import AtriumClient
import AtriumProtocol
import SwiftUI

/// A task's conversation, scrolled to the latest message, with the agent's state below it.
struct TaskChatView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let item: HostTask
    @Environment(TaskComposer.self) private var composer
    @Environment(HostDirectory.self) private var hosts
    @State private var pin = TimelinePin()
    @State private var anchorSpace = TimelineAnchorSpace()
    @State private var scrollPolicy = ConversationScrollPolicy()

    private static let bottomID = "bottom"

    private var task: WireTask { item.task }
    private var host: HostClient { item.host }

    var body: some View {
        let messages = host.conversations.transcripts[task.id]
        let pendingPrompts = host.conversations.pendingPrompts[task.id] ?? []
        // A prompt just sent shows the agent working with it, before the host
        // reports so, so the indicator arrives with the prompt's row.
        let footerStatus = host.conversations.footerStatus(for: task.id, status: task.status)
        let newestPromptID = pendingPrompts.last?.timelineID ?? messages?.last { $0.role == .user }?.id
        // A prompt sent from this device starts the latest turn, held at the
        // top. A pending prompt held there hands over to the transcript's
        // message once that shows it.
        let anchorID = pendingPrompts.last?.timelineID ?? anchorSpace.anchorID.flatMap { id in
            id.hasPrefix("pending-") ? newestPromptID : id
        }
        let turns = ConversationTurns(messages: messages ?? [], pendingPrompts: pendingPrompts, status: task.status)
        let sections = TimelineSections(messages: turns.messages, pendingPrompts: pendingPrompts, anchorID: anchorID)

        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(sections.historyMessages.enumerated(), id: \.element.id) { index, message in
                            TranscriptMessageRow(
                                message: message, isStreaming: turns.liveIDs.contains(message.id),
                                edit: message.editTarget != nil
                                    ? { composer.beginEditing(message, in: item) } : nil,
                                editEnabled: task.actions.contains(.editMessage) && pendingPrompts.isEmpty && composer.messageEdit?.isSubmitting != true
                            )
                            .padding(.top, ChatMessageSpacing.before(message.role, after: index > 0 ? sections.historyMessages[index - 1].role : nil))
                        }
                        ForEach(sections.historyPendingPrompts.enumerated(), id: \.element.id) { index, prompt in
                            PendingPromptView(prompt: prompt, item: item)
                                .padding(.top, ChatMessageSpacing.before(.user, after: index > 0 ? .user : sections.historyMessages.last?.role))
                        }
                        if sections.hasTurn {
                            // At least the resting viewport's height, so its
                            // prompt can scroll to the top.
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(sections.turnMessages.enumerated(), id: \.element.id) { index, message in
                                    TranscriptMessageRow(
                                        message: message, isStreaming: turns.liveIDs.contains(message.id),
                                        edit: message.editTarget != nil
                                            ? { composer.beginEditing(message, in: item) } : nil,
                                        editEnabled: task.actions.contains(.editMessage) && pendingPrompts.isEmpty && composer.messageEdit?.isSubmitting != true
                                    )
                                    .padding(.top, ChatMessageSpacing.before(message.role, after: index > 0 ? sections.turnMessages[index - 1].role : nil))
                                }
                                ForEach(sections.turnPendingPrompts.enumerated(), id: \.element.id) { index, prompt in
                                    PendingPromptView(prompt: prompt, item: item)
                                        .padding(.top, ChatMessageSpacing.before(.user, after: index > 0 ? .user : sections.turnMessages.last?.role))
                                }
                                TaskChatStatusFooter(status: footerStatus)
                                    .padding(.top, footerStatus == .processing || footerStatus == .waiting ? ChatMessageSpacing.standard : 0)
                            }
                            .onGeometryChange(for: CGFloat.self) { geometry in
                                geometry.size.height
                            } action: { height in
                                anchorSpace.setTurnHeight(height)
                            }
                            .frame(minHeight: anchorSpace.turnMinimumHeight, alignment: .top)
                            .id(TimelineAnchorSpace.turnID)
                            .padding(.top, ChatMessageSpacing.before(
                                sections.turnMessages.first?.role ?? .user,
                                after: sections.historyPendingPrompts.isEmpty ? sections.historyMessages.last?.role : .user
                            ))
                        } else {
                            TaskChatStatusFooter(status: footerStatus)
                                .padding(.top, footerStatus == .processing || footerStatus == .waiting ? ChatMessageSpacing.standard : 0)
                        }

                    }
                    // Keep the scroll target available independently of lazy rows.
                    Color.clear
                        .frame(height: TimelineAnchorSpace.bottomTargetHeight)
                        .id(Self.bottomID)
                        .accessibilityHidden(true)
                }
                // A prompt just sent closes the keyboard in the same turn, before
                // its turn has been measured, but it always fits below itself.
                .followsComposerOnKeyboard { [host, anchorSpace, composer, taskID = task.id] in
                    composer.messageEdit != nil || host.conversations.pendingPrompts[taskID]?.isEmpty == false || anchorSpace.isHolding
                }
            }
            // The container is what shows between the bars and keyboard. The
            // latest turn is sized for it with the keyboard hidden, so its
            // prompt holds still as the keyboard comes and goes. Before the
            // bars are laid out, there are no insets yet.
            .onScrollGeometryChange(for: CGSize?.self) { geometry in
                geometry.contentInsets.top > 0 ? geometry.containerSize : nil
            } action: { _, size in
                if let size { anchorSpace.noteViewport(size) }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardDidHideNotification)) { _ in
                anchorSpace.keyboardDidHide()
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .contentMargins(.top, 10, for: .scrollContent)
            .contentMargins(.horizontal, 15, for: .scrollContent)
            .contentMargins(.bottom, 20, for: .scrollContent)
            .scrollDismissesKeyboard(.interactively)
            .showsSendFlightsUnclipped()
            .scrollsOnComposerFocus {
                scrollToLatest(with: proxy, animated: scrollPolicy.animatesGrowth)
            } scrollToEditingMessage: { id in
                scrollToEditingMessage(id, with: proxy)
            }
            .onChange(of: composer.messageEdit?.id) { _, id in
                guard id != nil, composer.isFocused, let messageID = composer.messageEdit?.messageID else { return }
                scrollToEditingMessage(messageID, with: proxy)
            }
            .onChange(of: composer.editedPromptID) { _, id in
                guard let id else { return }
                // Replacing an older turn shrinks the transcript, so it cannot
                // use the normal new-row count check to establish this anchor.
                scrollPolicy.noteSend()
                anchorSpace.anchorID = "pending-" + id.uuidString
                scrollToLatest(with: proxy, holdingPrompt: true)
            }
            // Another task, or a transcript arriving for the first time, opens
            // at its newest message, pinned. The scroll view itself is kept
            // rather than recreated with a new identity: the bottom bar
            // re-adopts a new scroll view, so recreating it while a task opens
            // makes the composer's placeholder spring.
            .onChange(of: TranscriptTracker(
                taskID: task.id,
                hasTranscript: messages != nil,
                count: (messages?.count ?? 0) + pendingPrompts.count,
                lastID: pendingPrompts.last?.timelineID ?? messages?.last?.id
            ), initial: true) { oldTracker, newTracker in
                guard composer.messageEdit == nil else { return }
                if host.drafts[oldTracker.taskID]?.taskID == newTracker.taskID, anchorSpace.anchorID == nil {
                    anchorSpace.anchorID = pendingPrompts.last?.timelineID
                        ?? host.conversations.displayMessages(for: task.id).last {
                            $0.role == .user && $0.id.hasPrefix("pending-")
                        }?.id
                }
                let continuesConversation = oldTracker.taskID == newTracker.taskID || TaskDraft.isDraftID(oldTracker.taskID)
                let preservesTurn = continuesConversation && anchorSpace.anchorID.map {
                    host.conversations.containsTimelineID($0, in: task.id)
                } == true
                if scrollPolicy.observe(from: oldTracker, to: newTracker, preservingTurn: preservesTurn) {
                    pin = TimelinePin()
                    anchorSpace.reset()
                    scrollToLatest(with: proxy, animated: false)
                    return
                }
                // Scroll when a new message arrives. A shrinking transcript
                // keeps the reader where they are.
                guard newTracker.lastID != oldTracker.lastID,
                      newTracker.count >= oldTracker.count else { return }
                // A prompt sent from this device is held at the top, and each
                // prompt after it takes its place there.
                let isNewPrompt = newTracker.lastID == newestPromptID
                let sentFromHere = newTracker.lastID?.hasPrefix("pending-") == true
                if isNewPrompt, sentFromHere || anchorSpace.anchorID != nil {
                    anchorSpace.anchorID = newestPromptID
                    scrollToLatest(with: proxy, holdingPrompt: true)
                    return
                }
                guard oldTracker.lastID != nil else { return }
                // The transcript showing a pending prompt swaps one row for
                // another at the end; let the send's scroll finish.
                let confirmedPendingPrompt = oldTracker.lastID?.hasPrefix("pending-") == true
                    && newTracker.count == oldTracker.count
                guard !confirmedPendingPrompt else { return }
                // A reply arriving below a prompt held at the top leaves the
                // prompt there for the reader to read down from.
                guard !sections.hasTurn else { return }
                scrollToLatest(with: proxy)
            }
            // Only the reader scrolling decides whether the timeline stays
            // pinned. Checking the position as content grows would unpin it
            // whenever growth lands mid-scroll, such as the working indicator
            // appearing while a sent prompt is still sliding up.
            .onScrollPhaseChange { _, phase, context in
                switch phase {
                case .tracking, .interacting:
                    pin.isReaderScrolling = true
                case .idle:
                    guard pin.isReaderScrolling else { return }
                    pin.isReaderScrolling = false
                    pin.isPinned = context.geometry.isAtBottom
                default:
                    break
                }
            }
            // Content growing below a pinned timeline (a streaming reply, the
            // working indicator) carries it along, retargeting any scroll
            // already on its way.
            .onScrollGeometryChange(for: CGFloat.self, of: \.contentSize.height) { oldHeight, newHeight in
                guard composer.messageEdit == nil, newHeight > oldHeight, pin.isPinned, !pin.isReaderScrolling else { return }
                // A reply outgrowing the turn below a prompt held at the top
                // leaves the prompt where it is.
                guard !sections.hasTurn else { return }
                // Markdown can finish measuring after initial placement. Keep
                // those corrections immediate until a same-task update arrives.
                scrollToLatest(with: proxy, animated: scrollPolicy.animatesGrowth)
            }
            .overlay {
                if messages == nil, let error = host.transcriptErrors[task.id] {
                    ContentUnavailableView {
                        Label("Couldn’t Load Conversation", systemImage: "exclamationmark.bubble")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") { host.reload(.transcript(taskID: task.id)) }
                    }
                } else if messages == nil {
                    ProgressView()
                        .controlSize(.large)
                } else if messages?.isEmpty == true, pendingPrompts.isEmpty {
                    ContentUnavailableView("No Messages Yet", systemImage: "bubble.left", description: Text("Send a prompt to start."))
                }
            }
        }

    }

    private func scrollToEditingMessage(_ id: String, with proxy: ScrollViewProxy) {
        pin.isPinned = false
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
            proxy.scrollTo(id, anchor: .bottom)
        }
    }

    /// Scrolls to the newest message: to the prompt held at the top, while
    /// its turn fits below it, else to the end.
    private func scrollToLatest(with proxy: ScrollViewProxy, holdingPrompt: Bool? = nil, animated: Bool = true) {
        pin.isPinned = true
        let holdsPrompt = holdingPrompt ?? anchorSpace.isHolding
        let shouldAnimate = animated && !reduceMotion
        var transaction = Transaction(animation: shouldAnimate ? .easeOut(duration: 0.25) : nil)
        transaction.disablesAnimations = !shouldAnimate
        withTransaction(transaction) {
            if holdsPrompt {
                proxy.scrollTo(TimelineAnchorSpace.turnID, anchor: .top)
            } else {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        }
    }
}

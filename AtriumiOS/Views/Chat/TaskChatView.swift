import SwiftUI

/// A task's conversation, scrolled to the latest message, with the agent's state below it.
struct TaskChatView: View {
    @Environment(CompanionClient.self) private var client
    let task: WireTask
    @State private var pin = TimelinePin()
    @State private var anchorSpace = TimelineAnchorSpace()

    private static let bottomID = "bottom"

    var body: some View {
        let messages = client.transcripts[task.id]
        let pendingPrompts = client.pendingPrompts[task.id] ?? []
        // A prompt just sent shows the agent working with it, before the host
        // reports so, so the indicator arrives with the prompt's row.
        let footerStatus: AgentThreadStatus = client.tasksAwaitingAgent[task.id] != nil && task.status != .waiting
            ? .processing
            : task.status
        let newestPromptID = pendingPrompts.last?.timelineID ?? messages?.last { $0.role == .user }?.id
        // A prompt sent from this device starts the latest turn, held at the
        // top. A pending prompt held there hands over to the transcript's
        // message once that shows it.
        let anchorID = pendingPrompts.last?.timelineID ?? anchorSpace.anchorID.flatMap { id in
            id.hasPrefix("pending-") ? newestPromptID : id
        }
        let sections = TimelineSections(messages: messages ?? [], pendingPrompts: pendingPrompts, anchorID: anchorID)
        // A reply followed by a prompt still on its way is finished, even
        // once the agent starts on that prompt.
        let streamingMessageID = task.status == .processing && pendingPrompts.isEmpty ? messages?.last?.id : nil

        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(sections.historyMessages) { message in
                            TranscriptMessageRow(message: message, isStreaming: message.id == streamingMessageID)
                        }
                        ForEach(sections.historyPendingPrompts) { prompt in
                            PendingPromptView(prompt: prompt, taskID: task.id)
                        }
                        if sections.hasTurn {
                            // At least the resting viewport's height, so its
                            // prompt can scroll to the top.
                            VStack(alignment: .leading, spacing: 16) {
                                ForEach(sections.turnMessages) { message in
                                    TranscriptMessageRow(message: message, isStreaming: message.id == streamingMessageID)
                                }
                                ForEach(sections.turnPendingPrompts) { prompt in
                                    PendingPromptView(prompt: prompt, taskID: task.id)
                                }
                                TaskChatStatusFooter(status: footerStatus)
                            }
                            .onGeometryChange(for: CGFloat.self) { geometry in
                                geometry.size.height
                            } action: { height in
                                anchorSpace.setTurnHeight(height)
                            }
                            .frame(minHeight: anchorSpace.turnMinimumHeight, alignment: .top)
                            .id(TimelineAnchorSpace.turnID)
                        } else {
                            TaskChatStatusFooter(status: footerStatus)
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
                .followsComposerOnKeyboard { [client, anchorSpace, taskID = task.id] in
                    client.pendingPrompts[taskID]?.isEmpty == false || anchorSpace.isHolding
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
            .contentMargins([.horizontal, .bottom], 20, for: .scrollContent)
            .scrollDismissesKeyboard(.interactively)
            .showsSendFlightsUnclipped()
            .scrollsOnComposerFocus {
                scrollToLatest(with: proxy)
            }
            // Another task, or a transcript arriving for the first time, opens
            // at its newest message, pinned. The scroll view itself is kept
            // rather than recreated with a new identity: the bottom bar
            // re-adopts a new scroll view, so recreating it while a task opens
            // makes the composer's placeholder spring.
            .onChange(of: "\(task.id)-\(messages != nil)") {
                pin = TimelinePin()
                anchorSpace.reset()
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
            .onChange(of: TranscriptTracker(
                count: (messages?.count ?? 0) + pendingPrompts.count,
                lastID: pendingPrompts.last?.timelineID ?? messages?.last?.id
            )) { oldTracker, newTracker in
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
                guard newHeight > oldHeight, pin.isPinned, !pin.isReaderScrolling else { return }
                // A reply outgrowing the turn below a prompt held at the top
                // leaves the prompt where it is.
                guard !sections.hasTurn else { return }
                scrollToLatest(with: proxy)
            }
            .overlay {
                if messages == nil {
                    ProgressView()
                        .controlSize(.large)
                } else if messages?.isEmpty == true, pendingPrompts.isEmpty {
                    if let draft = client.drafts[task.id] {
                        DraftAgentPicker(draft: draft)
                    } else {
                        ContentUnavailableView("No Messages Yet", systemImage: "bubble.left", description: Text("Send a prompt to start."))
                    }
                }
            }
        }
    }

    /// Scrolls to the newest message: to the prompt held at the top, while
    /// its turn fits below it, else to the end.
    private func scrollToLatest(with proxy: ScrollViewProxy, holdingPrompt: Bool? = nil) {
        pin.isPinned = true
        let holdsPrompt = holdingPrompt ?? anchorSpace.isHolding
        withAnimation(.easeOut(duration: 0.25)) {
            if holdsPrompt {
                proxy.scrollTo(TimelineAnchorSpace.turnID, anchor: .top)
            } else {
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        }
    }
}

import SwiftUI

/// A task's conversation, scrolled to the latest message, with the agent's state below it.
struct TaskChatView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.colorScheme) private var colorScheme
    @Environment(PromptFlights.self) private var flights
    let item: HostTask
    @Environment(TaskComposer.self) private var composer
    @Environment(HostDirectory.self) private var hosts
    @State private var pin = TimelinePin()
    @State private var anchorSpace = TimelineAnchorSpace()
    @State private var scrollPolicy = ConversationScrollPolicy()
    /// Counts the tasks the timeline has shown. Each starts a new lazy stack,
    /// which otherwise sizes the rows it hasn't measured from the last task's.
    @State private var timelineID = 0

    private static let topID = "top"
    private static let bottomID = "bottom"
    private static let footerID = "footer"

    private var task: WireTask { item.task }
    private var host: HostClient { item.host }
    /// The skills its prompts tint, once the composer has listed them.
    private var skillNames: Set<String> { host.skillNames(for: task) }

    var body: some View {
        // A prompt the transcript shows keeps its pending row's ID, so the
        // row stays put and its turn isn't held at the top again.
        let messages = host.conversations.transcripts[task.id].map { _ in host.conversations.displayMessages(for: task.id) }
        let pendingPrompts = host.conversations.pendingPrompts[task.id] ?? []
        // Waiting for the turn to end, until the host sends it as a prompt on its way.
        let queuedPrompt = task.queuedPrompt.flatMap { queued in
            queued.isSending || pendingPrompts.contains { $0.id == queued.id } ? nil : queued
        }
        // A prompt just sent shows the agent working with it, before the host
        // reports so, so the indicator arrives with the prompt's row.
        let footerStatus = host.conversations.footerStatus(for: task.id, status: item.progressStatus)
        let newestPromptID = pendingPrompts.last?.timelineID ?? messages?.last { $0.role == .user }?.id
        // A prompt sent from this device starts the latest turn, held at the
        // top. A pending prompt held there hands over to the transcript's
        // message once that shows it. A host can also give the held prompt a
        // new ID, as Claude does once it saves the turn; the prompt that
        // starts the latest turn then stays held in its place.
        let anchorID = pendingPrompts.last?.timelineID ?? anchorSpace.anchorID.flatMap { id in
            if id.hasPrefix("pending-") { return newestPromptID }
            guard messages?.contains(where: { $0.id == id }) == false else { return id }
            return messages?.last { $0.role == .user && !$0.isSteer }?.id
        }
        let turns = ConversationTurns(messages: messages ?? [], pendingPrompts: pendingPrompts, status: task.status)
        let sections = TimelineSections(messages: turns.messages, pendingPrompts: pendingPrompts, anchorID: anchorID)
        let editEnabled = task.actions.contains(.editMessage) && pendingPrompts.isEmpty
        let forkEnabled = task.actions.contains(.fork)
        let replyForks = forkEnabled
            ? ReplyForkPoint.points(in: turns.messages, liveIDs: turns.liveIDs, hasLaterPrompts: !pendingPrompts.isEmpty || queuedPrompt != nil)
            : [:]
        // The last row that shows anything, which a jump to the end is
        // checked against.
        let endRowID = footerStatus == .processing || footerStatus == .waiting
            ? Self.footerID : sections.historyPendingPrompts.last?.timelineID ?? sections.historyMessages.last?.id

        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Where a timeline shorter than the view rests.
                        Color.clear
                            .frame(height: 0)
                            .id(Self.topID)
                            .accessibilityHidden(true)
                        ForEach(sections.historyMessages.enumerated(), id: \.element.id) { index, message in
                            TranscriptMessageRow(
                                message: message, isStreaming: turns.liveIDs.contains(message.id),
                                edit: message.editTarget != nil
                                    ? PromptAction(isEnabled: { editEnabled && composer.canBeginEditing(message.id) }, perform: { composer.beginEditing(message, in: item) }) : nil,
                                fork: message.editTarget != nil
                                    ? PromptAction(isEnabled: { forkEnabled }, perform: { hosts.fork(item, into: task.provider, before: message) }) : nil,
                                forkReply: replyForks[message.id].map { point in { hosts.fork(item, into: task.provider, after: point) } }
                            )
                            .padding(.top, ChatMessageSpacing.before(message.role, after: index > 0 ? sections.historyMessages[index - 1].role : nil))
                        }
                        ForEach(sections.historyPendingPrompts.enumerated(), id: \.element.id) { index, prompt in
                            PendingPromptView(prompt: prompt)
                                .padding(.top, ChatMessageSpacing.before(.user, after: index > 0 ? .user : sections.historyMessages.last?.role))
                        }
                        if sections.hasTurn {
                            // The space above the turn is a row of its own: a
                            // lazy stack scrolls to a row's whole frame, so as
                            // the turn's padding it would hold the prompt that
                            // far below the top, showing the end of the
                            // message before it.
                            Color.clear
                                .frame(height: ChatMessageSpacing.before(
                                    sections.turnMessages.first?.role ?? .user,
                                    after: sections.historyPendingPrompts.isEmpty ? sections.historyMessages.last?.role : .user
                                ))
                                .accessibilityHidden(true)
                            // At least the resting viewport's height, so its
                            // prompt can scroll to the top.
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(sections.turnMessages.enumerated(), id: \.element.id) { index, message in
                                    TranscriptMessageRow(
                                        message: message, isStreaming: turns.liveIDs.contains(message.id),
                                        edit: message.editTarget != nil
                                            ? PromptAction(isEnabled: { editEnabled && composer.canBeginEditing(message.id) }, perform: { composer.beginEditing(message, in: item) }) : nil,
                                        fork: message.editTarget != nil
                                            ? PromptAction(isEnabled: { forkEnabled }, perform: { hosts.fork(item, into: task.provider, before: message) }) : nil,
                                        forkReply: replyForks[message.id].map { point in { hosts.fork(item, into: task.provider, after: point) } }
                                    )
                                    .padding(.top, ChatMessageSpacing.before(message.role, after: index > 0 ? sections.turnMessages[index - 1].role : nil))
                                }
                                ForEach(sections.turnPendingPrompts.enumerated(), id: \.element.id) { index, prompt in
                                    PendingPromptView(prompt: prompt)
                                        .padding(.top, ChatMessageSpacing.before(.user, after: index > 0 ? .user : sections.turnMessages.last?.role))
                                }
                                if let queuedPrompt {
                                    QueuedPromptView(prompt: queuedPrompt, item: item)
                                        .id(PendingPrompt.timelineID(queuedPrompt.id))
                                        .padding(.top, ChatMessageSpacing.before(
                                            .user, after: sections.turnPendingPrompts.isEmpty ? sections.turnMessages.last?.role : .user))
                                }
                                TaskChatStatusFooter(status: footerStatus, toolCall: turns.latestToolCall)
                                    .padding(.top, footerStatus == .processing || footerStatus == .waiting ? ChatMessageSpacing.standard : 0)
                            }
                            .onGeometryChange(for: CGFloat.self) { geometry in
                                geometry.size.height
                            } action: { height in
                                anchorSpace.setTurnHeight(height)
                            }
                            .frame(minHeight: anchorSpace.turnMinimumHeight, alignment: .top)
                            .id(TimelineAnchorSpace.turnID)
                        } else {
                            if let queuedPrompt {
                                QueuedPromptView(prompt: queuedPrompt, item: item)
                                    .id(PendingPrompt.timelineID(queuedPrompt.id))
                                    .padding(.top, ChatMessageSpacing.before(
                                        .user, after: sections.historyPendingPrompts.isEmpty ? sections.historyMessages.last?.role : .user))
                            }
                            TaskChatStatusFooter(status: footerStatus, toolCall: turns.latestToolCall)
                                .padding(.top, footerStatus == .processing || footerStatus == .waiting ? ChatMessageSpacing.standard : 0)
                                .id(Self.footerID)
                        }
                        // The end is a row of the lazy stack, so scrolling to it
                        // lays out the rows above it from the end. Placed after
                        // the stack, it's put where the stack's estimate of the
                        // rows above ends, and those rows can stay hidden once
                        // they're measured and the timeline ends higher.
                        Color.clear
                            .frame(height: TimelineAnchorSpace.bottomTargetHeight)
                            .id(Self.bottomID)
                            .accessibilityHidden(true)
                    }
                    .id(timelineID)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { flights.rowWidth = $0 }
                }
                .background { TimelineScrollViewFinder(flights: flights) }
                // A prompt just sent closes the keyboard in the same turn, before
                // its turn has been measured, but it always fits below itself.
                // A timeline that fits in the view rests at its top while the
                // composer moves over the space below it.
                .followsComposerOnKeyboard { [host, anchorSpace, composer, taskID = task.id] in
                    (pin.isPinned || pin.isNearEnd) && !pin.contentFits && !pin.isReaderScrolling && composer.messageEdit == nil
                        && host.conversations.pendingPrompts[taskID]?.isEmpty != false && !anchorSpace.isHolding
                }
                .dismissesComposerOnTap { [composer] in
                    // Resigning at once, rather than through the composer's
                    // focus, lets UIKit announce the keyboard hiding before
                    // the composer starts to shrink.
                    guard composer.isFocused else { return }
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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
            // Pages and images agents show in replies load from the task's host.
            .environment(\.chatMedia, ChatMedia(host: host, taskID: task.id, directory: task.path))
            .environment(\.skillNames, skillNames)
            // Opens at the end. Content shorter than the view rests at its
            // top: aligning it to the bottom gives the scroll view a top inset
            // that SwiftUI moves the offset by whenever it changes, as the
            // keyboard and composer come and go, past where it can rest.
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .contentMargins(.top, 10, for: .scrollContent)
            .contentMargins(.horizontal, 15, for: .scrollContent)
            // Three times the gap between messages, so the last one reads as
            // the end of the timeline rather than running into the composer.
            .contentMargins(.bottom, ChatMessageSpacing.standard * 3, for: .scrollContent)
            .scrollDismissesKeyboard(.interactively)
            .scrollsOnComposerFocus {
                // A reader who scrolled more than a screen back through the
                // conversation, or is still scrolling, stays where they are.
                guard pin.isPinned || pin.isNearEnd, !pin.isReaderScrolling else { return }
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
                holdLatestPrompt(with: proxy)
            }
            .onChange(of: reduceMotion, initial: true) { flights.reduceMotion = reduceMotion }
            .onChange(of: dynamicTypeSize, initial: true) { flights.dynamicTypeSize = dynamicTypeSize }
            .onChange(of: colorScheme, initial: true) { flights.colorScheme = colorScheme }
            .onChange(of: skillNames, initial: true) { flights.skillNames = skillNames }
            // Another task, or a transcript arriving for the first time, opens
            // at its newest message, pinned. The scroll view itself is kept
            // rather than recreated with a new identity, so the keyboard
            // follower stays attached to it.
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
                    if !continuesConversation {
                        timelineID += 1
                    }
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
                    holdLatestPrompt(with: proxy)
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
                // A reader who scrolled back through the conversation stays
                // where they are, as they do while a reply streams.
                guard pin.isPinned, !pin.isReaderScrolling else { return }
                scrollToLatest(with: proxy)
            }
            // The jump that makes room for a sent prompt slides on the render server.
            .onScrollGeometryChange(for: CGFloat.self, of: \.contentOffset.y) { old, new in
                guard !pin.isReaderScrolling else { return }
                flights.noteScroll(by: new - old)
            }
            // The composer growing, as the keyboard comes up or the draft gains
            // a line, takes a timeline kept at its end along; the keyboard
            // follower draws the move in step with the composer.
            .onScrollGeometryChange(for: FittingValue.self) { geometry in
                FittingValue(geometry.contentInsets.bottom, in: geometry)
            } action: { old, new in
                pin.contentFits = new.fits
                // Shrinking until the timeline fits, SwiftUI puts it where its
                // last scroll to the end now lands, past its top; see
                // `scrollToLatest`.
                guard new.value > old.value || (new.fits && !old.fits), composer.messageEdit == nil, pin.isPinned,
                      !pin.isReaderScrolling, !sections.hasTurn else { return }
                scrollToLatest(with: proxy, animated: false)
            }
            // Dragging the keyboard away scrolls the timeline a little off its
            // end, which shouldn't keep the composer from taking it back there.
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.distanceToEnd < geometry.containerSize.height
            } action: { _, isNearEnd in
                pin.isNearEnd = isNearEnd
            }
            // Only the reader scrolling decides whether the timeline stays
            // pinned. Checking the position as content grows would unpin it
            // whenever growth lands mid-scroll, such as the working indicator
            // appearing while a sent prompt is still sliding up.
            .onScrollPhaseChange { _, phase, context in
                switch phase {
                case .tracking:
                    pin.isReaderScrolling = true
                case .interacting, .decelerating:
                    pin.isReaderScrolling = true
                    // A jump's layout corrections expire when the reader takes over.
                    pin.endChecks = 0
                case .idle where pin.isReaderScrolling:
                    pin.isReaderScrolling = false
                    pin.isPinned = context.geometry.isAtBottom
                default:
                    break
                }
            }
            // A jump to the end lands where the lazy stack estimated it, which
            // can be past rows it then measures shorter, as when a task opens
            // with its transcript already loaded: SwiftUI pulls the offset in
            // but lays out none of the rows now in view, leaving the timeline
            // blank until the reader scrolls. Scrolling to the last row that
            // shows anything once the jump moves the timeline lays them out;
            // the end target can't, as the stack already has it where it's
            // asked to go. SwiftUI can move the offset a few times before the
            // jump settles. A timeline shorter than the view shows all its rows.
            .onScrollGeometryChange(for: CGFloat?.self) { geometry in
                geometry.contentFits ? nil : geometry.contentOffset.y
            } action: { _, offset in
                guard offset != nil, pin.endChecks > 0 else { return }
                pin.endChecks -= 1
                settleAtEnd(endRowID, sections: sections, with: proxy)
            }
            // Content growing below a pinned timeline (a streaming reply, the
            // working indicator) carries it along, retargeting any scroll
            // already on its way. Content shrinking under it, as the lazy stack
            // measures rows it had estimated, puts it straight back at the end:
            // SwiftUI pulls the offset in, but leaves the rows now in view hidden.
            .onScrollGeometryChange(for: FittingValue.self) { geometry in
                FittingValue(geometry.contentSize.height, in: geometry)
            } action: { old, new in
                pin.contentFits = new.fits
                let oldHeight = old.value, newHeight = new.value
                guard composer.messageEdit == nil, newHeight != oldHeight, pin.isPinned, !pin.isReaderScrolling else { return }
                // A reply outgrowing the turn below a prompt held at the top
                // leaves the prompt where it is.
                guard !sections.hasTurn else { return }
                // Markdown can finish measuring after initial placement. Keep
                // those corrections immediate until a same-task update arrives.
                scrollToLatest(with: proxy, animated: newHeight > oldHeight && scrollPolicy.animatesGrowth)
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
                } else if messages?.isEmpty == true, pendingPrompts.isEmpty, host.drafts[task.id] == nil {
                    ContentUnavailableView("No Messages Yet", systemImage: "bubble.left", description: Text("Send a prompt to start."))
                }
            }
        }

    }

    /// Puts a pinned timeline's last row at the end of the view, which lays
    /// out the rows above it.
    private func settleAtEnd(_ endRowID: String?, sections: TimelineSections, with proxy: ScrollViewProxy) {
        guard let endRowID, pin.isPinned, !pin.isReaderScrolling, !sections.hasTurn, composer.messageEdit == nil else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) { proxy.scrollTo(endRowID, anchor: .bottom) }
    }

    private func scrollToEditingMessage(_ id: String, with proxy: ScrollViewProxy) {
        pin.isPinned = false
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
            // A timeline that fits shows the message where it rests; see
            // `scrollToLatest`.
            proxy.scrollTo(pin.contentFits ? Self.topID : id, anchor: pin.contentFits ? .top : .bottom)
        }
    }

    /// Holds the latest prompt at the top of the timeline. A prompt just sent
    /// from here jumps there, and its copy and the content slide on the
    /// render server instead.
    private func holdLatestPrompt(with proxy: ScrollViewProxy) {
        guard flights.isSending else { return scrollToLatest(with: proxy, holdingPrompt: true) }
        flights.makeRoom { scrollToLatest(with: proxy, holdingPrompt: true, animated: false) }
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
            } else if pin.contentFits {
                // SwiftUI takes a short timeline asked to show its end past
                // its top, by as much as the top inset, and asks for that
                // again as the insets change.
                proxy.scrollTo(Self.topID, anchor: .top)
            } else {
                if !shouldAnimate { pin.endChecks = 3 }
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
        }
    }
}

/// A value of the timeline's scroll geometry, with whether its content
/// fits in the view, which a scroll to its end has to know first.
private struct FittingValue: Equatable {
    let value: CGFloat
    let fits: Bool

    init(_ value: CGFloat, in geometry: ScrollGeometry) {
        self.value = value
        fits = geometry.contentFits
    }
}

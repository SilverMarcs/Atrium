import SwiftUI

/// A task's conversation, scrolled to the latest message, with the agent's state below it.
struct TaskChatView: View {
    @Environment(CompanionClient.self) private var client
    @Environment(TaskComposer.self) private var composer
    let task: WireTask
    @State private var pin = TimelinePin()

    private static let bottomID = "bottom"

    var body: some View {
        let messages = client.transcripts[task.id]
        let pendingPrompts = client.pendingPrompts[task.id] ?? []
        // A prompt just sent shows the agent working with it, before the host
        // reports so, so the indicator arrives with the prompt's row.
        let footerStatus: AgentThreadStatus = client.tasksAwaitingAgent[task.id] != nil && task.status != .waiting
            ? .processing
            : task.status

        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(messages ?? []) { message in
                            switch message.role {
                            case .user:
                                UserMessageView(text: message.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n"))
                            case .assistant:
                                // A reply followed by a prompt still on its way is
                                // finished, even once the agent starts on that prompt.
                                AssistantMessageView(
                                    blocks: message.blocks,
                                    isStreaming: task.status == .processing
                                        && pendingPrompts.isEmpty
                                        && message.id == messages?.last?.id
                                )
                            }
                        }
                        ForEach(pendingPrompts) { prompt in
                            PendingPromptView(prompt: prompt, taskID: task.id)
                        }
                        TaskChatStatusFooter(status: footerStatus)
                    }
                    // Keep the scroll target available independently of lazy rows.
                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomID)
                        .accessibilityHidden(true)
                }
                .followsComposerOnKeyboard()
            }
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(.bottom, for: .alignment)
            .contentMargins(.top, 10, for: .scrollContent)
            .contentMargins([.horizontal, .bottom], 20, for: .scrollContent)
            .scrollDismissesKeyboard(.interactively)
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
                proxy.scrollTo(Self.bottomID, anchor: .bottom)
            }
            .onChange(of: TranscriptTracker(
                count: (messages?.count ?? 0) + pendingPrompts.count,
                lastID: pendingPrompts.last?.timelineID ?? messages?.last?.id
            )) { oldTracker, newTracker in
                guard oldTracker.lastID != nil else { return }
                // Scroll when a new message arrives. A shrinking transcript
                // keeps the reader where they are.
                guard newTracker.lastID != oldTracker.lastID,
                      newTracker.count >= oldTracker.count else { return }
                // The transcript showing a pending prompt swaps one row for
                // another at the end; let the send's scroll finish.
                let confirmedPendingPrompt = oldTracker.lastID?.hasPrefix("pending-") == true
                    && newTracker.count == oldTracker.count
                guard !confirmedPendingPrompt else { return }
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
                    // A prompt just sent is in view once the scroll to it
                    // ends, so the composer can close its keyboard.
                    composer.finishRevealingSentPrompt()
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

    private func scrollToLatest(with proxy: ScrollViewProxy) {
        pin.isPinned = true
        withAnimation(.easeOut(duration: 0.25)) {
            proxy.scrollTo(Self.bottomID, anchor: .bottom)
        }
    }
}

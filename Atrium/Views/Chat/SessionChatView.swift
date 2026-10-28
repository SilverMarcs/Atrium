import SwiftUI

/// A local client of the same transcript feed and task actions used by the companion.
struct SessionChatView: View {
  @Bindable var session: TaskSession
  @Environment(AgentIntegrationStore.self) private var integrations
  @Environment(TaskSessionController.self) private var sessions
  @Environment(WorkspaceStore.self) private var workspaces
  @AppStorage(ChatFontSize.key) private var chatFontSize = ChatFontSize.default
  @State private var client = SessionChatClient()
  @State private var isReaderScrolling = false
  @State private var scrollPolicy = ConversationScrollPolicy()
  @State private var sendAnimator = PromptSendAnimator()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var thread: AgentThread {
    integrations.threads.first { $0.id == session.id } ?? session.thread
  }

  var body: some View {
    let transcript = client.conversation.transcripts[session.id]
    let rows = client.conversation.rows(for: session.id)
    let prompts = client.pendingPrompts
    let footerStatus = client.conversation.footerStatus(for: session.id, status: thread.status)
    let streamingID =
      (thread.status == .processing || thread.status == .waiting) && !prompts.contains { $0.state != .failed }
      ? rows.last?.id : nil
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 8) {
          ForEach(rows) { row in
            SessionChatMessageRow(
              message: row.message,
              isStreaming: row.message.role == .assistant && row.id == streamingID,
              pendingPrompt: row.pendingPrompt,
              retry: { if let prompt = row.pendingPrompt { client.retry(prompt.id) } }
            )
            .transition(.identity)
          }
          TaskChatStatusFooter(status: footerStatus)
            .transition(.identity)
          if let error = client.actionError ?? client.feed?.error {
            Label(error, systemImage: "exclamationmark.triangle")
              .frame(maxWidth: .infinity)
              .foregroundStyle(.red)
              .padding(.vertical)

            Button("Retry") { client.feed?.refresh() }

          }
          Color.clear.frame(height: 32).id("bottom")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
        .frame(maxWidth: SessionChatLayout.maximumWidth)
        .frame(maxWidth: .infinity)
      }
      .scrollEdgeEffectHidden(true, for: .bottom)
      .scrollEdgeEffectHidden(false, for: .top)
      .scrollEdgeEffectStyle(.soft, for: .top)
      .defaultScrollAnchor(.bottom, for: .initialOffset)
      .defaultScrollAnchor(.bottom, for: .alignment)
      .showsSendFlightsUnclipped()
      .onScrollPhaseChange { _, phase, context in
        switch phase {
        case .tracking, .interacting:
          isReaderScrolling = true
        case .idle where isReaderScrolling:
          isReaderScrolling = false
          client.isPinned =
            context.geometry.contentOffset.y + context.geometry.containerSize.height
            >= context.geometry.contentSize.height - 40
        default:
          break
        }
      }
      .onScrollGeometryChange(for: CGSize.self) { geometry in
        CGSize(width: geometry.containerSize.height, height: geometry.contentSize.height)
      } action: { old, new in
        guard client.isPinned, !isReaderScrolling,
          new.height > old.height || new.width < old.width
        else { return }
        scrollToBottom(proxy, animated: scrollPolicy.animatesGrowth)
      }
      .overlay {
        if transcript == nil, rows.isEmpty, client.feed?.error == nil {
          ProgressView()
        } else if transcript?.isEmpty == true, prompts.isEmpty {
          Image(thread.provider.symbolName)
            .resizable()
            .scaledToFit()
            .frame(width: 100, height: 100)
            .foregroundStyle(thread.provider.color.gradient)
            .saturation(0)
            .allowsHitTesting(false)
        }
      }
      .safeAreaBar(edge: .bottom) {
        SessionChatComposer(
          prompt: $session.chatPrompt, images: $session.chatImages, provider: thread.provider,
          isSending: client.isSending, isProcessing: thread.status == .processing,
          actions: sessions.menuState(for: thread).allowed,
          send: send,
          interrupt: { client.interrupt(taskID: session.id) },
          noteSourceFrame: { frame in sendAnimator.sourceFrame = { frame } }
        )
        .frame(maxWidth: SessionChatLayout.maximumWidth)
        .frame(maxWidth: .infinity)
      }
      .onChange(
        of: TranscriptTracker(
          taskID: session.id,
          hasTranscript: transcript != nil,
          count: rows.count,
          lastID: rows.last?.id
        ), initial: true
      ) { old, new in
        if scrollPolicy.observe(from: old, to: new) {
          scrollToBottom(proxy, animated: false)
        }
      }
      .onChange(of: thread.status) { _, status in
        client.conversation.noteStatus(status, for: session.id)
      }
      .task(id: session.id) {
        client.start(
          session: session, integrations: integrations, sessions: sessions, workspaces: workspaces
        )
      }
      .onDisappear {
        client.stop()
        sendAnimator.cancelAll()
      }
    }
    .modifier(AgentInteractionPresentation(
      requests: integrations.interactions.filter { $0.taskID == session.id },
      respond: { request, decision in try await integrations.respond(to: request, with: decision) }
    ))
    .font(.system(size: chatFontSize))
    .environment(sendAnimator)
  }

  private func send() {
    scrollPolicy.noteSend()
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      client.send(session: session) { prompt in
        if !reduceMotion {
          sendAnimator.begin(prompt.id, text: prompt.text, from: sendAnimator.sourceFrame?())
        }
      }
    }
  }

  private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool) {
    let animates = animated && !reduceMotion
    var transaction = Transaction(animation: animates ? .easeOut(duration: 0.25) : nil)
    transaction.disablesAnimations = !animates
    withTransaction(transaction) {
      proxy.scrollTo("bottom", anchor: .bottom)
    }
  }

}

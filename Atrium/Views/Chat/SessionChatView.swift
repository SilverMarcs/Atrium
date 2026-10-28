import SwiftUI

/// A task's conversation on its host, with a composer that sends to its agent.
struct SessionChatView: View {
  let item: HostTask
  let project: Project?
  @Environment(AppModel.self) private var app
  @AppStorage(ChatFontSize.key) private var chatFontSize = ChatFontSize.default
  @State private var isPinned = true
  @State private var isReaderScrolling = false
  @State private var scrollPolicy = ConversationScrollPolicy()
  @State private var sendAnimator = PromptSendAnimator()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var host: HostClient { item.host }
  private var task: WireTask { item.task }
  private var conversation: ConversationStore { host.conversations }
  private var transcriptError: String? { host.transcriptErrors[task.id] }

  var body: some View {
    @Bindable var composer = app.composer(for: item.id)
    let transcript = conversation.transcripts[task.id]
    let rows = conversation.rows(for: task.id)
    let prompts = conversation.pendingPrompts[task.id] ?? []
    let footerStatus = conversation.footerStatus(for: task.id, status: task.status)
    let streamingID =
      (task.status == .processing || task.status == .waiting) && !prompts.contains { $0.state != .failed }
      ? rows.last?.id : nil
    ScrollViewReader { proxy in
      ScrollView {
        // Bottom-aligns short chats; the `.alignment` scroll anchor would stretch the toolbar down to the first row.
        ZStack(alignment: .bottom) {
          Color.clear
            .containerRelativeFrame(.vertical)
          LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(rows) { row in
              SessionChatMessageRow(
                message: row.message,
                isStreaming: row.message.role == .assistant && row.id == streamingID,
                pendingPrompt: row.pendingPrompt,
                retry: { if let prompt = row.pendingPrompt { host.retryPrompt(prompt.id, in: task.id) } }
              )
              .transition(.identity)
            }
            TaskChatStatusFooter(status: footerStatus)
              .transition(.identity)
            if let transcriptError {
              Label(transcriptError, systemImage: "exclamationmark.triangle")
                .frame(maxWidth: .infinity)
                .foregroundStyle(.red)
                .padding(.vertical)

              Button("Retry") { host.reload(.transcript(taskID: task.id)) }
            }
            Color.clear.frame(height: 32).id("bottom")
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 4)
          .frame(maxWidth: SessionChatLayout.maximumWidth)
          .frame(maxWidth: .infinity)
        }
      }
      .scrollEdgeEffectHidden(true, for: .bottom)
      .scrollEdgeEffectHidden(false, for: .top)
      .scrollEdgeEffectStyle(.soft, for: .top)
      .defaultScrollAnchor(.bottom, for: .initialOffset)
      .showsSendFlightsUnclipped()
      .onScrollPhaseChange { _, phase, context in
        switch phase {
        case .tracking, .interacting:
          isReaderScrolling = true
        case .idle where isReaderScrolling:
          isReaderScrolling = false
          isPinned =
            context.geometry.contentOffset.y + context.geometry.containerSize.height
            >= context.geometry.contentSize.height - 40
        default:
          break
        }
      }
      .onScrollGeometryChange(for: CGSize.self) { geometry in
        CGSize(width: geometry.containerSize.height, height: geometry.contentSize.height)
      } action: { old, new in
        guard isPinned, !isReaderScrolling,
          new.height > old.height || new.width < old.width
        else { return }
        scrollToBottom(proxy, animated: scrollPolicy.animatesGrowth)
      }
      .overlay {
        if transcript == nil, rows.isEmpty, transcriptError == nil {
          ProgressView()
        } else if transcript?.isEmpty == true, prompts.isEmpty, let draft = host.drafts[task.id] {
          DraftAgentPicker(host: host, draft: draft)
        } else if transcript?.isEmpty == true, prompts.isEmpty {
          Image(task.provider.symbolName)
            .resizable()
            .scaledToFit()
            .frame(width: 100, height: 100)
            .foregroundStyle(task.provider.color.gradient)
            .saturation(0)
            .allowsHitTesting(false)
        }
      }
      .safeAreaBar(edge: .bottom) {
        SessionChatComposer(
          prompt: $composer.prompt, images: $composer.images, provider: task.provider,
          isSending: conversation.isSending(in: task.id), isProcessing: task.status == .processing,
          actions: task.actions,
          send: { send(composer) },
          interrupt: { host.interrupt(task.id) },
          noteSourceFrame: { frame in sendAnimator.sourceFrame = { frame } }
        )
        .frame(maxWidth: SessionChatLayout.maximumWidth)
        .frame(maxWidth: .infinity)
      }
      .onChange(
        of: TranscriptTracker(
          taskID: task.id,
          hasTranscript: transcript != nil,
          count: rows.count,
          lastID: rows.last?.id
        ), initial: true
      ) { old, new in
        if scrollPolicy.observe(from: old, to: new) {
          scrollToBottom(proxy, animated: false)
        }
      }
      .onChange(of: task.status) { _, status in
        conversation.noteStatus(status, for: task.id)
      }
      .task(id: task.id) {
        // A draft has no conversation on the host until its first prompt creates it.
        guard !TaskDraft.isDraftID(task.id) else { return }
        await host.follow(.transcript(taskID: task.id))
      }
      .onDisappear {
        sendAnimator.cancelAll()
      }
    }
    .modifier(AgentInteractionPresentation(
      requests: task.interactions,
      respond: { request, decision in
        _ = try await host.request(.task(id: task.id, action: .respond(interactionID: request.id, decision: decision)))
      }
    ))
    .font(.system(size: chatFontSize))
    .environment(sendAnimator)
    .environment(\.openURL, OpenURLAction { url in
      // Links to files in the project open in its editor; anything else goes to the system.
      guard let project, url.isFileURL || url.scheme == nil else { return .systemAction }
      let link = url.isFileURL ? url.absoluteString : (url.relativeString.removingPercentEncoding ?? url.relativeString)
      Task {
        if await !project.openLink(link), project.isLocal { NSWorkspace.shared.open(url) }
      }
      return .handled
    })
  }

  private func send(_ composer: ComposerDraft) {
    let text = composer.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty || !composer.images.isEmpty, !conversation.isSending(in: task.id) else { return }
    scrollPolicy.noteSend()
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      let id = host.sendPrompt(text, images: composer.images.map(\.data), to: task.id)
      if !reduceMotion {
        sendAnimator.begin(id, text: text, from: sendAnimator.sourceFrame?())
      }
      composer.prompt = ""
      composer.images = []
      isPinned = true
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

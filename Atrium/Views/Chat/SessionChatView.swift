import AtriumClient
import AtriumProtocol
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
    let editing = composer.messageEdit
    let transcript = conversation.transcripts[task.id]
    let prompts = conversation.pendingPrompts[task.id] ?? []
    let turns = ConversationTurns(
      messages: conversation.displayMessages(for: task.id), pendingPrompts: prompts, status: task.status)
    let rows = conversation.rows(for: task.id, turns: turns)
    let footerStatus = conversation.footerStatus(for: task.id, status: task.status)
    ScrollViewReader { proxy in
      ScrollView {
        // Bottom-aligns short chats; the `.alignment` scroll anchor would stretch the toolbar down to the first row.
        ZStack(alignment: .bottom) {
          Color.clear
            .containerRelativeFrame(.vertical)
          LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(rows.enumerated(), id: \.element.id) { index, row in
              SessionChatMessageRow(
                message: row.message,
                isStreaming: turns.liveIDs.contains(row.id),
                edit: row.pendingPrompt == nil && row.message.editTarget != nil
                    ? { composer.messageEdit = ConversationMessageEdit(message: row.message, item: item) } : nil,
                editEnabled: task.actions.contains(.editMessage) && prompts.isEmpty && composer.messageEdit?.isSubmitting != true,
                pendingPrompt: row.pendingPrompt,
                retry: { if let prompt = row.pendingPrompt { host.retryPrompt(prompt.id, in: task.id) } }
              )
              .padding(.top, ChatMessageSpacing.before(row.message.role, after: index > 0 ? rows[index - 1].message.role : nil))
              .transition(.identity)
            }
            TaskChatStatusFooter(status: footerStatus)
              .padding(.top, footerStatus == .processing || footerStatus == .waiting ? ChatMessageSpacing.standard : 0)
              .transition(.identity)
            if let transcriptError {
              Label(transcriptError, systemImage: "exclamationmark.triangle")
                .padding(.top, ChatMessageSpacing.standard)
                .frame(maxWidth: .infinity)
                .foregroundStyle(.red)
                .padding(.vertical)

              Button("Retry") { host.reload(.transcript(taskID: task.id)) }
                .padding(.top, ChatMessageSpacing.standard)
            }
            Color.clear.frame(height: 32).padding(.top, ChatMessageSpacing.standard).id("bottom")
          }
          .padding(.horizontal, 16)
          .padding(.vertical, 4)
          .frame(maxWidth: SessionChatLayout.maximumWidth)
          .frame(maxWidth: .infinity)
        }
      }
      // Pages agents show in replies load from the task's host.
      .environment(host)
      .environment(\.earlierPageIDs, turns.earlierPageIDs)
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
        guard composer.messageEdit == nil, isPinned, !isReaderScrolling,
          new.height > old.height || new.width < old.width
        else { return }
        scrollToBottom(proxy, animated: scrollPolicy.animatesGrowth)
      }
      .overlay {
        if transcript == nil, rows.isEmpty, transcriptError == nil {
          ProgressView()
        } else if transcript?.isEmpty == true, prompts.isEmpty {
          let draft = host.drafts[task.id]
          if draft == nil || !host.enabledProviders.isEmpty {
            let provider = draft?.provider ?? task.provider
            Image(provider.symbolName)
              .resizable()
              .scaledToFit()
              .frame(width: 109, height: 109)
              .foregroundStyle(.tertiary)
              .contentTransition(.symbolEffect(.replace))
              .accessibilityLabel(provider.name)
              .allowsHitTesting(false)
          }
        }
      }
      .safeAreaBar(edge: .bottom) {
        VStack(spacing: 0) {
          if transcript?.isEmpty == true, prompts.isEmpty, let draft = host.drafts[task.id] {
            NewChatPicker(hosts: app.hosts, host: host, draft: draft)
              .padding(.top, 8)
          }
          SessionChatComposer(
            prompt: $composer.inputText, images: $composer.inputImages, provider: task.provider,
            isSending: conversation.isSending(in: task.id), isProcessing: task.status == .processing,
            actions: task.actions,
            send: { send(composer) },
            interrupt: { host.interrupt(task.id) },
            edit: composer.messageEdit,
            cancelEdit: { composer.messageEdit = nil },
            noteSourceFrame: { frame in sendAnimator.sourceFrame = { frame } }
          )
        }
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
      .onChange(of: composer.messageEdit?.id) { _, id in
        guard id != nil, let messageID = composer.messageEdit?.messageID else { return }
        isPinned = false
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
          proxy.scrollTo(messageID, anchor: .center)
        }
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
    .modifier(ComposerDropHandler(isEnabled: editing?.isSubmitting != true) { content in
      guard composer.messageEdit === editing, editing?.isSubmitting != true else { return }
      switch content {
      case .text(let text):
        composer.inputText += text
      case .image(let image):
        try ComposerPasteContent.checkImageLimit(
          composer.inputImages.count + (editing?.images.count ?? 0), maximum: 10
        )
        composer.inputImages.append(image)
      }
    })
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
    if let edit = composer.messageEdit {
      Task {
        if await edit.submit(send: { text, images in send(text, images: images) }) {
          composer.messageEdit = nil
        }
      }
      return
    }
    let text = composer.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty || !composer.images.isEmpty, !conversation.isSending(in: task.id) else { return }
    send(text, images: composer.images.map(\.data))
    composer.prompt = ""
    composer.images = []
  }

  private func send(_ text: String, images: [Data]) {
    scrollPolicy.noteSend()
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      let id = host.sendPrompt(text, images: images, to: task.id)
      if !reduceMotion {
        sendAnimator.begin(id, text: text, from: sendAnimator.sourceFrame?())
      }
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

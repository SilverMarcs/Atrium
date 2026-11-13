import AtriumClient
import AtriumProtocol
import SwiftUI

/// A task's conversation on its host, with a composer that sends to its agent.
struct SessionChatView: View {
  let item: HostTask
  let project: Project?
  @Environment(AppModel.self) private var app
  @AppStorage(ChatFontSize.key) private var chatFontSize = ChatFontSize.default
  @AppStorage(SendMode.key) private var sendMode = SendMode.steer
  @State private var pin = TimelinePin()
  @State private var anchorSpace = TimelineAnchorSpace()
  @State private var turnFill = TurnFill()
  @State private var scrollPolicy = ConversationScrollPolicy()
  @State private var flights = PromptFlights()
  @State private var links = ChatLinkOpener()
  /// The pages the task's agents showed, which the timeline keeps loaded as it scrolls.
  @State private var pages = LoadedChatPages()
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private static let bottomID = "bottom"
  /// Space below the newest message, so it reads as the end of the timeline
  /// rather than running into the composer.
  private static let bottomGap = ChatMessageSpacing.standard * 3

  private var host: HostClient { item.host }
  private var task: WireTask { item.task }
  private var conversation: ConversationStore { host.conversations }
  private var transcriptError: String? { host.transcriptErrors[task.id] }

  var body: some View {
    let composer = app.hosts.composer(for: item.id)
    let actions = promptActions(composer)
    let transcript = conversation.transcripts[task.id]
    let prompts = conversation.pendingPrompts[task.id] ?? []
    let turns = ConversationTurns(
      messages: conversation.displayMessages(for: task.id), pendingPrompts: prompts, status: task.status)
    let rows = conversation.rows(for: task.id, turns: turns, queued: task.queuedPrompt)
    let footerStatus = conversation.footerStatus(for: task.id, status: item.progressStatus)
    // A queued prompt hasn't started a turn yet.
    let queuedRowID = rows.last?.queuedPrompt == nil ? nil : rows.last?.id
    let newestPromptID = rows.last { $0.message.role == .user && $0.queuedPrompt == nil }?.id
    // A prompt sent from here starts the latest turn, held at the top of the
    // timeline. A host can give the held prompt a new ID, as Claude does once
    // it saves the turn; the prompt that starts the latest turn stays held instead.
    let anchorID = anchorSpace.anchorID.flatMap { id in
      rows.contains { $0.id == id } ? id
        : rows.last { $0.message.role == .user && !$0.message.isSteer && $0.queuedPrompt == nil }?.id
    }
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
                isRewindable: row.pendingPrompt == nil && row.message.editTarget != nil,
                pendingPrompt: row.pendingPrompt,
                queuedPrompt: row.queuedPrompt
              )
              .equatable()
              // The first message has the usual gap above it too, so held at
              // the top it sits as far below the toolbar as a later prompt.
              .padding(.top, index == 0 ? ChatMessageSpacing.standard : ChatMessageSpacing.before(row.message.role, after: rows[index - 1].message.role))
              .background {
                if row.id == anchorID { TurnTopReporter(fill: turnFill) }
              }
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
            TurnFiller(fill: turnFill, anchorSpace: anchorSpace, isHolding: anchorID != nil, bottomGap: Self.bottomGap)
            // The end is a row of the lazy stack, so scrolling to it lays out
            // the rows above it from the end.
            Color.clear
              .frame(height: Self.bottomGap)
              .id(Self.bottomID)
              .accessibilityHidden(true)
          }
          .coordinateSpace(.named(TurnFill.coordinateSpace))
          .modifier(ReplyPrefetch(rows: rows, liveIDs: turns.liveIDs))
          .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { flights.rowWidth = $0 }
          .background { TimelineScrollViewFinder(flights: flights) }
          .padding(.horizontal, 16)
          .padding(.top, 4)
          .frame(maxWidth: SessionChatLayout.maximumWidth)
          .frame(maxWidth: .infinity)
        }
      }
      // Pages and images agents show in replies load from the task's host.
      .environment(\.chatMedia, ChatMedia(host: host, taskID: task.id, directory: task.path))
      .environment(pages)
      .environment(\.promptActions, actions)
      .environment(\.earlierPageIDs, turns.earlierPageIDs)
      .environment(flights)
      .scrollEdgeEffectHidden(true, for: .bottom)
      .scrollEdgeEffectHidden(false, for: .top)
      .scrollEdgeEffectStyle(.soft, for: .top)
      .defaultScrollAnchor(.bottom, for: .initialOffset)
      // Only the reader scrolling decides whether the timeline stays pinned.
      // Checking the position as content grows would unpin it whenever growth
      // lands mid-scroll.
      .onScrollPhaseChange { _, phase, context in
        switch phase {
        case .tracking, .interacting:
          pin.isReaderScrolling = true
        case .idle where pin.isReaderScrolling:
          pin.isReaderScrolling = false
          pin.isPinned = context.geometry.isAtBottom
        default:
          break
        }
      }
      .onScrollGeometryChange(for: CGSize.self, of: \.containerSize) { _, size in
        anchorSpace.noteViewport(size)
      }
      // Content growing below a pinned timeline (a streaming reply, the
      // working indicator) carries it along; content shrinking under it, as a
      // finished reply folds or the lazy stack measures rows it had
      // estimated, puts it straight back at the end. A reply below a prompt
      // held at the top grows into the space under it instead, and once it
      // outgrows that the reader reads down from the prompt.
      .onScrollGeometryChange(for: CGSize.self) { geometry in
        CGSize(width: geometry.containerSize.height, height: geometry.contentSize.height)
      } action: { old, new in
        flights.noteLayout()
        guard composer.messageEdit == nil, new != old, pin.isPinned, !pin.isReaderScrolling, anchorID == nil else { return }
        let grew = new.height > old.height || new.width < old.width
        scrollToLatest(proxy, holding: nil, animated: grew && scrollPolicy.animatesGrowth && !flights.isSending)
      }
      // The jump that makes room for a sent prompt slides on the render server.
      .onScrollGeometryChange(for: CGFloat.self, of: \.contentOffset.y) { old, new in
        guard !pin.isReaderScrolling else { return }
        flights.noteScroll(by: new - old)
      }
      .overlay {
        if transcript == nil, rows.isEmpty, transcriptError == nil {
          ProgressView()
        }
      }
      .safeAreaInset(edge: .bottom) {
        VStack(spacing: 0) {
          if transcript?.isEmpty == true, prompts.isEmpty, let draft = host.drafts[task.id] {
            NewChatPicker(hosts: app.hosts, host: host, draft: draft)
              .padding(.top, 8)
          }
          // A subagent answers only to its own agent.
          if !task.isSubagent {
            SessionChatComposer(
              composer: composer, provider: task.provider,
              isSending: conversation.isSending(in: task.id),
              actions: task.actions,
              send: { send(composer, mode: sendMode) },
              interrupt: { composer.stop(item) },
              noteSourceFrame: { frame in flights.sourceFrame = { frame } }
            )
          }
        }
        .frame(maxWidth: SessionChatLayout.maximumWidth)
        .frame(maxWidth: .infinity)
      }
      // Another task, or a transcript arriving for the first time, opens at
      // its newest message, pinned.
      .onChange(
        of: TranscriptTracker(
          taskID: task.id,
          hasTranscript: transcript != nil,
          count: rows.count,
          lastID: rows.last?.id,
          queuedRowID: queuedRowID
        ), initial: true
      ) { old, new in
        guard composer.messageEdit == nil else { return }
        // A draft's first prompt carries on in the task the host creates for it.
        if host.drafts[old.taskID]?.taskID == new.taskID, anchorSpace.anchorID == nil {
          anchorSpace.anchorID = rows.last { $0.message.role == .user && $0.id.hasPrefix("pending-") }?.id
        }
        let continuesConversation = old.taskID == new.taskID || TaskDraft.isDraftID(old.taskID)
        let preservesTurn = continuesConversation && anchorSpace.anchorID.map {
          conversation.containsTimelineID($0, in: task.id)
        } == true
        if scrollPolicy.observe(from: old, to: new, preservingTurn: preservesTurn) {
          pin = TimelinePin()
          anchorSpace.reset()
          turnFill.reset()
          scrollToLatest(proxy, holding: nil, animated: false)
          return
        }
        // A queued prompt the host sends starts the next turn in its own row,
        // held at the top like a prompt sent then.
        if let queued = old.queuedRowID, new.queuedRowID == nil, queued == newestPromptID {
          hold(queued, proxy)
          return
        }
        // Scroll when a new message arrives. A shrinking transcript keeps the
        // reader where they are.
        guard new.lastID != old.lastID, new.count >= old.count else { return }
        // A prompt sent from here is held at the top, and each prompt after
        // it takes its place there, even when the reader had scrolled up.
        let sentFromHere = new.lastID?.hasPrefix("pending-") == true
        if new.lastID == newestPromptID, let newestPromptID, sentFromHere || anchorSpace.anchorID != nil {
          hold(newestPromptID, proxy)
          return
        }
        guard old.lastID != nil else { return }
        // A reply arriving below a prompt held at the top leaves the prompt
        // there for the reader to read down from.
        guard anchorID == nil else { return }
        scrollToLatest(proxy, holding: nil)
      }
      .onChange(of: composer.messageEdit?.id) { _, id in
        guard id != nil, let messageID = composer.messageEdit?.messageID else { return }
        pin.isPinned = false
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.25)) {
          proxy.scrollTo(messageID, anchor: .center)
        }
      }
      .onChange(of: composer.editedPromptID) { _, id in
        guard let id else { return }
        // Replacing an older turn shrinks the transcript, so it can't use the
        // new-row check above to hold its prompt.
        hold("pending-" + id.uuidString, proxy)
      }
      .onChange(of: chatFontSize, initial: true) { flights.fontSize = chatFontSize }
      .onChange(of: reduceMotion, initial: true) { flights.reduceMotion = reduceMotion }
      .task(id: task.id) {
        // A draft has no conversation on the host until its first prompt creates it.
        guard !TaskDraft.isDraftID(task.id) else { return }
        await host.follow(.transcript(taskID: task.id))
      }
      .onDisappear {
        flights.cancelAll()
        app.hosts.releaseComposer(for: item.id)
      }
    }
    .modifier(AgentInteractionPresentation(
      // Requests from the work below this task come up here too, as those sessions aren't listed.
      requests: task.interactions + item.subagentRequests,
      respond: { request, decision in
        _ = try await host.request(.task(id: request.taskID, action: .respond(interactionID: request.id, decision: decision)))
      },
      // Requests from subagents are answered in their session's own terminal too.
      openTerminal: host.isLocal && task.actions.contains(.openTerminal)
        ? { host.send(.task(id: task.id, action: .openTerminal)) } : nil
    ))
    .focusedSceneValue(\.latestPromptEdit, latestPromptEdit(rows: rows, actions: actions))
    .font(.system(size: chatFontSize))
    .composerDictationLifecycle(composer)
    .composerDropHandler(composer)
    // One action for the chat's lifetime: a new one on every update would
    // update every reply's Markdown view.
    .environment(\.openURL, links.action)
    .onChange(of: project?.id, initial: true) { links.project = project }
  }

  /// Reads the task's state when a bubble's menu asks, rather than handing
  /// every row values that change with each send.
  private func promptActions(_ composer: TaskComposer) -> PromptActions {
    PromptActions(
      isEditEnabled: { [host, taskID = task.id] messageID in
        host.task(taskID)?.actions.contains(.editMessage) == true
          && host.conversations.pendingPrompts[taskID]?.isEmpty != false
          && composer.canBeginEditing(messageID)
      },
      edit: { [host, taskID = task.id] message in
        guard let task = host.displayedTask(taskID) else { return }
        composer.beginEditing(message, in: HostTask(host: host, task: task))
      },
      isForkEnabled: { [host, taskID = task.id] in host.task(taskID)?.actions.contains(.fork) == true },
      fork: { [host, hosts = app.hosts, taskID = task.id] message in
        guard let task = host.displayedTask(taskID) else { return }
        hosts.fork(HostTask(host: host, task: task), into: task.provider, before: message)
      },
      retry: { [host, taskID = task.id] id in host.retryPrompt(id, in: taskID) },
      editQueued: { [host, taskID = task.id] in
        guard let task = host.displayedTask(taskID) else { return }
        composer.editQueuedPrompt(of: HostTask(host: host, task: task))
      },
      sendQueuedNow: { [host, taskID = task.id] in
        guard let task = host.displayedTask(taskID) else { return }
        composer.sendQueuedPromptNow(of: HostTask(host: host, task: task))
      }
    )
  }

  /// The newest prompt's bubble Edit action, offered when its menu would offer it.
  private func latestPromptEdit(rows: [ConversationRow], actions: PromptActions) -> LatestPromptEdit? {
    guard let row = rows.last(where: { $0.message.role == .user && $0.queuedPrompt == nil }),
          row.pendingPrompt == nil, row.message.editTarget != nil,
          actions.isEditEnabled(row.id) else { return nil }
    return LatestPromptEdit(messageID: row.id) { [message = row.message] in actions.edit(message) }
  }

  /// Sends with nothing else animating; the sent bubble flies in on its own.
  private func send(_ composer: TaskComposer, mode: SendMode) {
    var transaction = Transaction(animation: nil)
    transaction.disablesAnimations = true
    withTransaction(transaction) { composer.submit(to: item, animator: flights, mode: mode) }
  }

  /// Holds a prompt sent from here at the top of the timeline, as the start
  /// of the latest turn. A prompt just sent jumps there once the timeline
  /// has laid out its row, and its copy and the content slide instead.
  private func hold(_ promptID: String, _ proxy: ScrollViewProxy) {
    scrollPolicy.noteSend()
    anchorSpace.anchorID = promptID
    turnFill.reset()
    guard flights.isSending else { return scrollToLatest(proxy, holding: promptID) }
    flights.makeRoom { scrollToLatest(proxy, holding: promptID, animated: false) }
  }

  /// Scrolls to the newest message: to `holding`, a prompt held at the top
  /// of the timeline, or else to the end. A sent prompt's scroll jumps, and
  /// its copy and the content slide on the render server instead.
  private func scrollToLatest(_ proxy: ScrollViewProxy, holding promptID: String?, animated: Bool = true) {
    pin.isPinned = true
    let animates = animated && !reduceMotion
    var transaction = Transaction(animation: animates ? .easeOut(duration: 0.25) : nil)
    transaction.disablesAnimations = !animates
    withTransaction(transaction) {
      if let promptID {
        proxy.scrollTo(promptID, anchor: .top)
      } else {
        proxy.scrollTo(Self.bottomID, anchor: .bottom)
      }
    }
  }
}

/// Opens links in replies: files in the project in its editor, files elsewhere
/// on this Mac in Finder, and anything else with the system.
@MainActor
final class ChatLinkOpener {
  var project: Project?

  private(set) lazy var action = OpenURLAction { [weak self] url in
    self?.open(url) ?? .systemAction
  }

  private func open(_ url: URL) -> OpenURLAction.Result {
    guard let project, url.isFileURL || url.scheme == nil else { return .systemAction }
    let link = url.isFileURL ? url.absoluteString : (url.relativeString.removingPercentEncoding ?? url.relativeString)
    Task {
      if await !project.openLink(link), project.isLocal {
        FileService.openOutsideProject(link, relativeTo: project.root.path)
      }
    }
    return .handled
  }
}

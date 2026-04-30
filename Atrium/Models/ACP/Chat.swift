import Foundation
import Observation
import ACP

@Observable
final class Chat: Identifiable, Hashable, Codable {
    var id = UUID()
    var title: String = "New Chat"
    var acpSessionId: String?
    var provider: AgentProvider = .codex
    var permissionMode: PermissionMode = .bypassPermissions
    /// Raw model id as exposed by the agent (e.g. "claude-sonnet-4-7"). Empty
    /// string means "no specific model selected" — picker resolves the
    /// default lazily from `ModelCatalog`. Kept as a String so adding/removing
    /// models on the agent side doesn't require an enum migration.
    var model: String = ""
    var date: Date = Date()
    var sortOrder: Int = 0
    var turnCount: Int = 0
    var isArchived: Bool = false

    var usedTokens: Int = 0
    var contextSize: Int = 0
    var plan: [PlanEntry] = []
    private(set) var messages: [Message] = []
    private(set) var checkpoints: [Checkpoint] = []
    var pendingRevertedPrompts: [String] = []

    @ObservationIgnored
    weak var workspace: Workspace?

    @ObservationIgnored
    var session = ACPSession()

    @ObservationIgnored
    private var currentTurnMessage: Message?

    @ObservationIgnored
    private var suppressNextTurnEvents: Bool = false

    @ObservationIgnored
    var pendingContent: [ContentBlock]?

    var prompt: String = ""
    var pendingAttachments: [ChatAttachment] = []

    var hasNotification: Bool = false

    var isActive: Bool { session.isConnected }

    private var checkpointNamespace: String { id.uuidString }

    init(title: String = "New Chat", provider: AgentProvider = .codex, permissionMode: PermissionMode = .bypassPermissions, model: String? = nil, sortOrder: Int = 0) {
        self.title = title
        self.provider = provider
        self.permissionMode = permissionMode
        self.model = model ?? ModelCatalog.shared.defaultModel(for: provider)?.rawValue ?? ""
        self.sortOrder = sortOrder
    }

    // MARK: - Codable

    private enum CodingKeys: String, CodingKey {
        case id, title, acpSessionId, provider, permissionMode, model, date, sortOrder, turnCount, isArchived
        case usedTokens, contextSize, plan, messages, checkpoints, pendingRevertedPrompts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.acpSessionId = try c.decodeIfPresent(String.self, forKey: .acpSessionId)
        self.provider = try c.decodeIfPresent(AgentProvider.self, forKey: .provider) ?? .codex
        self.permissionMode = try c.decodeIfPresent(PermissionMode.self, forKey: .permissionMode) ?? .bypassPermissions
        self.model = try c.decodeIfPresent(String.self, forKey: .model) ?? ""
        self.date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        self.sortOrder = try c.decodeIfPresent(Int.self, forKey: .sortOrder) ?? 0
        self.turnCount = try c.decodeIfPresent(Int.self, forKey: .turnCount) ?? 0
        self.isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        self.usedTokens = try c.decodeIfPresent(Int.self, forKey: .usedTokens) ?? 0
        self.contextSize = try c.decodeIfPresent(Int.self, forKey: .contextSize) ?? 0
        self.plan = try c.decodeIfPresent([PlanEntry].self, forKey: .plan) ?? []
        self.messages = try c.decodeIfPresent([Message].self, forKey: .messages) ?? []
        self.checkpoints = try c.decodeIfPresent([Checkpoint].self, forKey: .checkpoints) ?? []
        self.pendingRevertedPrompts = try c.decodeIfPresent([String].self, forKey: .pendingRevertedPrompts) ?? []
        for msg in messages { msg.chat = self }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(acpSessionId, forKey: .acpSessionId)
        try c.encode(provider, forKey: .provider)
        try c.encode(permissionMode, forKey: .permissionMode)
        try c.encode(model, forKey: .model)
        try c.encode(date, forKey: .date)
        try c.encode(sortOrder, forKey: .sortOrder)
        try c.encode(turnCount, forKey: .turnCount)
        try c.encode(isArchived, forKey: .isArchived)
        try c.encode(usedTokens, forKey: .usedTokens)
        try c.encode(contextSize, forKey: .contextSize)
        try c.encode(plan, forKey: .plan)
        try c.encode(messages, forKey: .messages)
        try c.encode(checkpoints, forKey: .checkpoints)
        try c.encode(pendingRevertedPrompts, forKey: .pendingRevertedPrompts)
    }

    // MARK: - Hashable

    static func == (lhs: Chat, rhs: Chat) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    // MARK: - Connection Lifecycle

    func connectIfNeeded() {
        guard !session.isConnected && !session.isConnecting else { return }
        guard let directory = workspace?.directory else { return }

        session.provider = provider
        session.permissionMode = permissionMode
        session.model = model
        session.usedTokens = usedTokens
        session.contextSize = contextSize
        session.plan = plan
        session.setWorkingDirectory(directory)
        wireLiveCallbacks()

        if let acpId = acpSessionId {
            Task { await session.relaunchAndLoadSession(SessionId(acpId)) }
        } else {
            session.connect(workingDirectory: directory)
        }
    }

    func sendMessage(_ text: String, attachments: [ChatAttachment] = []) {
        var msgBlocks: [MessageBlock] = []
        if !text.isEmpty {
            msgBlocks.append(MessageBlock(type: .text, text: text))
        }
        for a in attachments {
            msgBlocks.append(MessageBlock(
                type: .image,
                imageData: a.data,
                imageMimeType: a.mimeType
            ))
        }
        guard !msgBlocks.isEmpty else { return }

        // A fresh prompt supersedes any error left over from the prior turn —
        // clear it so the red banner doesn't linger above the new exchange.
        session.error = nil

        let pm = Message(role: .user, turnIndex: turnCount + 1)
        pm.blocks = msgBlocks
        pm.chat = self
        messages.append(pm)
        date = Date()

        var content: [ContentBlock] = []
        // Prepended only on the wire — never appended to `messages`, so it stays
        // invisible in the UI but reaches the agent so it can drop the
        // reverted turns from its retained context.
        if let revertNote = buildRevertNote() {
            content.append(.text(TextContent(text: revertNote)))
            pendingRevertedPrompts.removeAll()
        }
        if !text.isEmpty {
            content.append(.text(TextContent(text: text)))
        }
        for a in attachments {
            content.append(.image(ImageContent(data: a.base64, mimeType: a.mimeType)))
        }

        pendingAttachments.removeAll()

        session.isProcessing = true

        // Create the assistant message immediately so it appears in the UI
        // before the first API response arrives.
        let assistantMsg = Message(role: .assistant, turnIndex: turnCount + 1)
        assistantMsg.chat = self
        messages.append(assistantMsg)
        currentTurnMessage = assistantMsg

        if session.isConnected {
            session.send(content: content)
        } else {
            pendingContent = content
            connectIfNeeded()
        }
        scheduleSave()
    }

    func disconnect() {
        session.onTurnComplete = nil
        session.onSessionUpdate = nil
        session.onConnected = nil
        session.disconnect()
    }

    // MARK: - Live Callbacks

    private func wireLiveCallbacks() {
        session.onSessionUpdate = { [weak self] update in
            guard let self, !self.suppressNextTurnEvents else { return }
            self.handleLiveUpdate(update)
        }

        session.delegate.onPermissionRequest = { [weak self] prompt in
            self?.notify("Permission requested")
        }

        session.onTurnComplete = { [weak self] in
            guard let self else { return }
            if self.suppressNextTurnEvents {
                // The just-finished turn was cancelled by a revert; drop its
                // bookkeeping (no turnCount bump, no checkpoint capture) so the
                // reverted state stays authoritative.
                self.suppressNextTurnEvents = false
                self.currentTurnMessage = nil
                return
            }
            self.turnCount += 1
            self.date = Date()
            self.currentTurnMessage = nil

            if let newTitle = await self.session.fetchSessionTitle(), !newTitle.isEmpty {
                self.title = newTitle
            }

            self.scheduleSave()
            self.notify("Finished responding")

            guard let dir = self.workspace?.directory else { return }

            do {
                let snapshots = try await CheckpointService.captureCheckpoint(
                    workspace: URL(fileURLWithPath: dir),
                    chatId: self.checkpointNamespace,
                    turn: self.turnCount
                )
                var checkpoint = Checkpoint(turnIndex: self.turnCount)
                checkpoint.repoSnapshots = snapshots
                self.checkpoints.append(checkpoint)
            } catch {
                print("[Checkpoint] capture failed: \(error.localizedDescription)")
            }
        }

        session.onConnected = { [weak self] in
            guard let self else { return }
            if let id = self.session.sessionId?.value, self.acpSessionId != id {
                self.acpSessionId = id
            }
            self.date = Date()
            self.scheduleSave()

            if let content = self.pendingContent {
                self.pendingContent = nil
                self.session.send(content: content)
            }

            if self.turnCount == 0 && !self.checkpoints.contains(where: { $0.turnIndex == 0 }) {
                Task { [weak self] in
                    guard let self, let dir = self.workspace?.directory else { return }
                    do {
                        let snapshots = try await CheckpointService.captureCheckpoint(
                            workspace: URL(fileURLWithPath: dir),
                            chatId: self.checkpointNamespace,
                            turn: 0
                        )
                        var checkpoint = Checkpoint(turnIndex: 0)
                        checkpoint.repoSnapshots = snapshots
                        self.checkpoints.append(checkpoint)
                    } catch {
                        print("[Checkpoint] baseline capture failed: \(error.localizedDescription)")
                    }
                }
            }
        }
    }

    // MARK: - Live Update Handling

    private func getOrCreateTurnMessage() -> Message {
        if let existing = currentTurnMessage { return existing }
        let pm = Message(role: .assistant, turnIndex: turnCount + 1)
        pm.chat = self
        messages.append(pm)
        currentTurnMessage = pm
        return pm
    }

    private func handleLiveUpdate(_ update: SessionUpdate) {
        switch update {
        case .userMessageChunk:
            break
        case .agentMessageChunk(let content):
            if case .text(let tc) = content {
                getOrCreateTurnMessage().appendToLastBlock(ofType: .text, text: tc.text)
            }
        case .agentThoughtChunk(let content):
            if case .text(let tc) = content {
                getOrCreateTurnMessage().appendToLastBlock(ofType: .thought, text: tc.text)
            }
        case .toolCall(let update):
            getOrCreateTurnMessage().addToolCall(
                toolCallId: update.toolCallId,
                title: update.title ?? update.kind?.rawValue.capitalized ?? "Tool",
                kind: update.kind,
                status: update.status ?? .pending,
                diff: Self.firstDiff(in: update.content)
            )
        case .toolCallUpdate(let details):
            getOrCreateTurnMessage().updateToolCall(
                id: details.toolCallId,
                title: details.title,
                kind: details.kind,
                status: details.status,
                diff: details.content.flatMap(Self.firstDiff)
            )
        case .usageUpdate(let usage):
            usedTokens = usage.used
            contextSize = usage.size
            session.usedTokens = usage.used
            session.contextSize = usage.size
        case .plan(let updatedPlan):
            plan = updatedPlan.entries
            session.plan = updatedPlan.entries
        case .availableCommandsUpdate(let commands):
            session.availableCommands = commands
        case .currentModeUpdate(let modeId):
            if let mode = PermissionMode.allCases.first(where: { $0.configValue(for: provider) == modeId }) {
                permissionMode = mode
                session.permissionMode = mode
            }
        case .sessionInfoUpdate(let info):
            if let newTitle = info.title {
                title = newTitle
            }
        case .configOptionUpdate(let configOptions):
            for option in configOptions {
                guard case .select(let select) = option.kind else { continue }
                switch option.id.value {
                case "model":
                    let value = select.currentValue.value
                    model = value
                    session.model = value
                    ModelCatalog.shared.ingestSelect(select.options, provider: provider)
                case "mode":
                    if let mode = PermissionMode.allCases.first(where: { $0.configValue(for: provider) == select.currentValue.value }) {
                        permissionMode = mode
                        session.permissionMode = mode
                    }
                default:
                    break
                }
            }
        default:
            break
        }
    }

    // MARK: - Revert

    func revert(toBeforeTurn turn: Int) async {
        guard turn >= 1, turn <= turnCount else { return }
        let restoreToTurn = turn - 1
        let oldTurnCount = turnCount
        let workspaceURL = (workspace?.directory).map { URL(fileURLWithPath: $0) }
        let snapshotsToRestore = checkpoints.first { $0.turnIndex == restoreToTurn }?.repoSnapshots

        // Cancel any in-flight turn without tearing down the agent session,
        // so the agent retains conversation context. The hidden note injected
        // on the next prompt tells it to disregard the reverted turns.
        if session.isProcessing {
            suppressNextTurnEvents = true
            session.stopStreaming()
        }

        if let workspaceURL, let snapshots = snapshotsToRestore {
            do {
                try await CheckpointService.restoreCheckpoint(workspace: workspaceURL, snapshots: snapshots)
            } catch {
                print("[Revert] filesystem restore failed: \(error.localizedDescription)")
            }
        }

        if let workspaceURL {
            await CheckpointService.deleteCheckpoints(
                workspace: workspaceURL,
                chatId: checkpointNamespace,
                afterTurn: restoreToTurn,
                throughTurn: oldTurnCount
            )
        }

        applyReverted(toBeforeTurn: turn)
        scheduleSave()
    }

    // Sole place revert mutates Chat state. Keep all trimming here so
    // `revert` only orchestrates async I/O around this single reducer.
    private func applyReverted(toBeforeTurn turn: Int) {
        let revertedUserPrompts = messages
            .filter { $0.turnIndex >= turn && $0.role == .user }
            .map(\.text)
            .filter { !$0.isEmpty }

        prompt = messages.first { $0.turnIndex == turn && $0.role == .user }?.text ?? ""
        messages.removeAll { $0.turnIndex >= turn }
        checkpoints.removeAll { $0.turnIndex >= turn }
        turnCount = turn - 1
        date = Date()
        currentTurnMessage = nil
        pendingRevertedPrompts.append(contentsOf: revertedUserPrompts)
    }

    private func buildRevertNote() -> String? {
        guard !pendingRevertedPrompts.isEmpty else { return nil }
        var lines: [String] = []
        lines.append("[System note from the user's IDE — not from the user themselves.")
        lines.append("The user has reverted the conversation. Please disregard the following \(pendingRevertedPrompts.count) prior user message(s) and any of your replies to them — treat them as if they never happened, and continue from the context that preceded them. The on-disk file state has also been rolled back to that earlier point.")
        lines.append("Reverted user message(s):")
        for (i, p) in pendingRevertedPrompts.enumerated() {
            let snippet = p.count > 500 ? String(p.prefix(500)) + "…" : p
            lines.append("  \(i + 1). \(snippet)")
        }
        lines.append("End of system note. The user's actual next message follows below.]")
        return lines.joined(separator: "\n")
    }

    // MARK: - Persistence

    private func scheduleSave() {
        workspace?.store?.scheduleSave()
    }

    // MARK: - Notifications

    private func notify(_ reason: String) {
        guard !session.isReplaying else { return }
        guard let workspace else { return }
        hasNotification = true
        AppDelegate.sendChatNotification(
            workspaceTitle: workspace.name,
            body: reason,
            workspaceID: workspace.id,
            chatID: id
        )
    }

    // MARK: - Helpers
    
    var displayTitle: String {
        if !title.isEmpty, title != "New Chat" {
            return title
        }
        if let lastUserMessage = messages.last(where: { $0.role == .user }), !lastUserMessage.text.isEmpty {
            return String(lastUserMessage.text.prefix(30))
        }
        return title
    }

    private static func firstDiff(in content: [ToolCallContent]) -> ToolCallDiff? {
        for item in content {
            if case .diff(let diff) = item { return diff }
        }
        return nil
    }
}

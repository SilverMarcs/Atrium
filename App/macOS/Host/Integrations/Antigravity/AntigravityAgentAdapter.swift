import AtriumProtocol
import Foundation
import OSLog

/// Antigravity through `agy acp`, its Agent Client Protocol server. Antigravity
/// is the agent: it owns the conversations, tools, models and sign-in, saved
/// where its terminal app reads them too. Atrium opens a session in the server
/// to show or prompt a chat, which replays its saved conversation, and closes
/// it when the chat settles. What ACP lacks, forks, rewinds, names and
/// deletion, goes through the server's language server, as Antigravity's
/// terminal app does it.
@MainActor
final class AntigravityAgentAdapter: AgentProviderAdapter {
    let provider = AgentProvider.antigravity
    let capabilities: AgentCapabilities = [.sideChatImages]
    var onEvent: ((AgentEvent) -> Void)?
    private(set) var defaultSettings: TaskStartSettings?

    private let connection = AntigravityConnection()
    private let instructions: ChatInstructions
    private let fullAccess = AntigravityFullAccess()
    private var sessions: [String: Session] = [:]
    private var opening: [String: Task<Session, Error>] = [:]
    private var decisions: [String: Pending] = [:]
    /// Side chats by session ID: the session they ask about, and how many
    /// messages they took from it, which they don't show.
    private var sideChats: [String: (parentID: String, inherited: Int)] = [:]
    /// Side chats whose first prompt hasn't marked where they begin yet.
    private var unmarkedSideChats: Set<String> = []
    /// The commands and skills the server last listed, by the folder of the session it listed them for.
    private var commands: [String: [AgentSkill]] = [:]
    private var isEnabled = true

    private let log = Logger(subsystem: "Atrium", category: "Antigravity")

    private final class Session {
        let directory: String
        var conversation: AntigravityConversation
        var status: AgentThreadStatus = .idle
        var settings = AntigravitySettings()
        var contextUsage: AgentContextUsage?
        var title: String?
        /// A name to give the conversation once Antigravity has named it after its first prompt.
        var pendingTitle: String?
        /// Prompts the server hasn't finished: a steer joins the turn in
        /// progress, which ends its earlier prompt.
        var prompts = 0
        init(id: String, directory: String) {
            self.directory = directory
            conversation = AntigravityConversation(sessionID: id)
        }
    }

    private struct Pending {
        let request: AntigravityRequest
        let decision: AntigravityDecision
        let sessionID: String
    }

    init(instructions: ChatInstructions) {
        self.instructions = instructions
        connection.onNotification = { [weak self] method, params in self?.receive(method, params) }
        connection.onRequest = { [weak self] request in self?.receive(request) }
        connection.onClose = { [weak self] in self?.closed() }
    }

    // MARK: - Listing

    func listThreads() async throws -> [AgentThread] {
        try await start()
        var threads: [AgentThread] = []
        var cursor: String?
        repeat {
            var params: [String: Any] = [:]
            if let cursor { params["cursor"] = cursor }
            let page = try await connection.request("session/list", params)
            threads += (page["sessions"] as? [[String: Any]] ?? []).compactMap(thread)
            cursor = page["nextCursor"] as? String
        } while cursor != nil
        return threads
    }

    func readThread(_ sessionID: String) async throws -> AgentThread? {
        try await listThreads().first { $0.sessionID == sessionID }
    }

    private func thread(_ row: [String: Any]) -> AgentThread? {
        guard let id = row["sessionId"] as? String,
              let directory = row["cwd"] as? String, directory != AntigravityConnection.folder.filePath else { return nil }
        let reported = (row["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let updated = (row["updatedAt"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
        return describe(AgentThread(
            sessionID: id, provider: .antigravity, title: reported.isEmpty ? "New Antigravity chat" : reported,
            directory: directory, updatedAt: updated ?? .now, status: .unknown, isMainTask: true,
            hasProviderTitle: !reported.isEmpty))
    }

    /// The thread with what its open session reports.
    private func describe(_ source: AgentThread) -> AgentThread {
        var thread = source
        if let sideChat = sideChats[thread.sessionID] {
            thread.title = "Side Chat"
            thread.hasProviderTitle = true
            thread.isMainTask = false
            thread.sideChatParentSessionID = sideChat.parentID
        }
        guard let session = sessions[thread.sessionID] else { return thread }
        if let title = session.title, !thread.isSideChat {
            thread.title = title
            thread.hasProviderTitle = true
        }
        thread.status = session.status
        thread.model = session.settings.model
        thread.reasoningEffort = session.settings.thinkingLevel
        thread.permissionMode = session.settings.permissionMode(fullAccess: fullAccess.contains(thread.sessionID))
        thread.contextUsage = session.contextUsage
        return thread
    }

    // MARK: - Sessions

    func openConversation(_ thread: AgentThread) async throws {
        _ = try await session(of: thread)
    }

    /// The thread's session, loaded in the server, which replays its conversation first.
    private func session(of thread: AgentThread) async throws -> Session {
        if let session = sessions[thread.sessionID] { return session }
        if let task = opening[thread.sessionID] { return try await task.value }
        let id = thread.sessionID
        let task = Task { () throws -> Session in
            try await start()
            let session = Session(id: id, directory: thread.directory)
            // The replay arrives before the reply, as updates for the session.
            sessions[id] = session
            do {
                let reply = try await connection.request("session/load", ["sessionId": id, "cwd": thread.directory, "mcpServers": []],
                                                         timeout: .seconds(120))
                session.settings = AntigravitySettings(configOptions: reply["configOptions"] as? [[String: Any]] ?? [])
            } catch {
                if sessions[id] === session { sessions[id] = nil }
                throw error
            }
            return session
        }
        opening[id] = task
        defer { opening[id] = nil }
        let session = try await task.value
        onEvent?(.threadUpdated(sessionID: id, update: AgentThreadUpdate(status: session.status)))
        onEvent?(.transcriptChanged(sessionID: id))
        onEvent?(.threadInvalidated(sessionID: id))
        return session
    }

    func createThread(directory: String, settings: TaskStartSettings?, title: String?) async throws -> AgentThread {
        try await start()
        let blocks = instructions.forNewChat
        // Antigravity keeps the appended prompt with the conversation, for every later load.
        let reply = try await connection.request("session/new", [
            "cwd": directory, "mcpServers": [],
            "_meta": ["antigravity": ["systemPrompt": ["append": AgentInstructions.text(blocks)]]],
        ])
        guard let id = reply["sessionId"] as? String else { throw IntegrationError(message: "Antigravity didn’t start a session.") }
        let session = Session(id: id, directory: directory)
        session.settings = AntigravitySettings(configOptions: reply["configOptions"] as? [[String: Any]] ?? [])
        sessions[id] = session
        instructions.record(blocks, for: "\(provider.rawValue):\(id)")
        if let model = settings?.model {
            try await apply(.model(model, reasoningEffort: settings?.reasoningEffort), to: id, in: session)
        }
        if let mode = settings?.permissionMode { try await apply(.permissionMode(mode), to: id, in: session) }
        // Antigravity names a conversation after its first prompt, so a name given now waits for that.
        session.pendingTitle = title
        return describe(AgentThread(
            sessionID: id, provider: .antigravity, title: title ?? "New Antigravity chat", directory: directory,
            updatedAt: .now, status: .idle, isMainTask: true, hasProviderTitle: title != nil, projectDirectory: directory))
    }

    /// Closes the session in the server; a turn in progress ends with it.
    func stopThread(_ thread: AgentThread) async throws {
        opening[thread.sessionID]?.cancel()
        guard sessions.removeValue(forKey: thread.sessionID) != nil else { return }
        withdrawDecisions(of: thread.sessionID)
        _ = try? await connection.request("session/close", ["sessionId": thread.sessionID], timeout: .seconds(10))
        onEvent?(.threadUpdated(sessionID: thread.sessionID, update: AgentThreadUpdate(status: .unknown)))
    }

    func renameThread(_ thread: AgentThread, to title: String) async throws {
        try await name(thread.sessionID, title)
    }

    private func name(_ id: String, _ title: String) async throws {
        _ = try await connection.languageServer("UpdateConversationAnnotations", [
            "cascadeId": id, "annotations": ["title": title], "mergeAnnotations": true,
        ])
        sessions[id]?.title = title
        onEvent?(.threadUpdated(sessionID: id, update: AgentThreadUpdate(title: title)))
    }

    /// Deletes the conversation from Antigravity's history, as its terminal app's `/resume` does.
    func deleteThread(_ thread: AgentThread) async throws {
        try await stopThread(thread)
        _ = try await connection.languageServer("DeleteCascadeTrajectory", ["cascadeId": thread.sessionID])
        fullAccess.set(false, for: thread.sessionID)
        onEvent?(.threadDeleted(sessionID: thread.sessionID))
        onEvent?(.listInvalidated)
    }

    /// Antigravity copies the conversation, whole or up to the step before a
    /// prompt. A fork before the first prompt has nothing to copy, so it's a new chat.
    func forkThread(_ thread: AgentThread, before messageID: String?) async throws -> AgentThread {
        let ordinal = try messageID.map { try promptOrdinal($0) }
        let last = try await steps(of: thread.sessionID).lastStep(beforePrompt: ordinal)
        guard last >= 0 else {
            let settings = TaskStartSettings(model: thread.model, reasoningEffort: thread.reasoningEffort, permissionMode: thread.permissionMode)
            return try await createThread(directory: thread.directory, settings: settings, title: thread.forkTitle)
        }
        let id = try await copy(thread, through: last)
        try await name(id, thread.forkTitle)
        instructions.record(instructions.blocks(for: thread.id), for: "\(provider.rawValue):\(id)")
        onEvent?(.listInvalidated)
        return describe(AgentThread(
            sessionID: id, provider: .antigravity, title: thread.forkTitle, directory: thread.directory, updatedAt: .now,
            status: .unknown, isMainTask: true, hasProviderTitle: true, projectDirectory: thread.projectDirectory))
    }

    /// A copy of the conversation through a step, which keeps the instructions it was started with.
    private func copy(_ thread: AgentThread, through step: Int) async throws -> String {
        let reply = try await connection.languageServerReply("ForkConversation", [
            "sourceCascadeId": thread.sessionID, "forkAtStepIndex": step,
        ])
        guard let id = reply["newCascadeId"] as? String else { throw IntegrationError(message: "Antigravity didn’t fork the conversation.") }
        fullAccess.set(fullAccess.contains(thread.sessionID), for: id)
        return id
    }

    /// A side chat is a copy of the conversation so far, told with its first
    /// prompt that what it inherited is only for reference. It shows only what
    /// it's asked, and is deleted when it ends.
    func startSideChat(of thread: AgentThread) async throws -> AgentThread {
        let last = try await steps(of: thread.sessionID).lastStep(beforePrompt: nil)
        guard last >= 0 else { throw IntegrationError(message: "There's nothing to ask about yet.") }
        let id = try await copy(thread, through: last)
        // Named for Antigravity's own history, where it shows until it ends.
        _ = try? await connection.languageServer("UpdateConversationAnnotations", [
            "cascadeId": id, "annotations": ["title": "Side chat · \(thread.title)"], "mergeAnnotations": true,
        ])
        sideChats[id] = (thread.sessionID, 0)
        unmarkedSideChats.insert(id)
        instructions.record(instructions.blocks(for: thread.id), for: "\(provider.rawValue):\(id)")
        let sideChat = AgentThread(sessionID: id, provider: .antigravity, title: "Side Chat", directory: thread.directory,
                                   updatedAt: .now, status: .unknown, projectDirectory: thread.projectDirectory)
        let session = try await session(of: sideChat)
        sideChats[id]?.inherited = session.conversation.messages.count
        onEvent?(.transcriptChanged(sessionID: id))
        return describe(sideChat)
    }

    func endSideChat(_ thread: AgentThread) async {
        guard sideChats[thread.sessionID] != nil else { return }
        try? await deleteThread(thread)
        sideChats[thread.sessionID] = nil
        unmarkedSideChats.remove(thread.sessionID)
    }

    /// Rewinds the conversation only, keeping files as they are: the server
    /// lets the session go while its language server reverts it, then loads it again.
    func rewind(_ thread: AgentThread, before messageID: String) async throws -> [TranscriptMessage] {
        guard (sessions[thread.sessionID]?.prompts ?? 0) == 0 else {
            throw IntegrationError(message: "Wait for Antigravity to finish or stop it before editing a message.")
        }
        let last = try await steps(of: thread.sessionID).lastStep(beforePrompt: promptOrdinal(messageID))
        if sessions.removeValue(forKey: thread.sessionID) != nil {
            withdrawDecisions(of: thread.sessionID)
            _ = try? await connection.request("session/close", ["sessionId": thread.sessionID], timeout: .seconds(10))
        }
        _ = try await connection.languageServer("RevertToCascadeStep", [
            "cascadeId": thread.sessionID, "stepIndex": last, "conversationOnly": true,
        ])
        return try await transcript(for: thread)
    }

    /// The conversation's steps, read off the main actor: a long one's are large.
    private func steps(of id: String) async throws -> AntigravitySteps {
        let data = try await connection.languageServer("GetCascadeTrajectorySteps", ["cascadeId": id])
        return try await Task.detached { try JSONDecoder().decode(AntigravitySteps.self, from: data) }.value
    }

    private func promptOrdinal(_ messageID: String) throws -> Int {
        guard let ordinal = AntigravityConversation.ordinal(ofPrompt: messageID) else {
            throw IntegrationError(message: "That message can’t be edited.")
        }
        return ordinal
    }

    /// The terminal app takes the conversation over, so the server lets it go
    /// and loads it again, with what the terminal added, when the chat next needs it.
    func prepareLaunch(for thread: AgentThread) async throws -> AgentLaunch {
        guard UUID(uuidString: thread.sessionID) != nil else { throw IntegrationError(message: "Invalid Antigravity session identifier.") }
        try await stopThread(thread)
        return AgentLaunch(executable: "agy", arguments: ["--conversation", thread.sessionID])
    }

    // MARK: - Conversation

    func transcript(for thread: AgentThread) async throws -> [TranscriptMessage] {
        let messages = try await session(of: thread).conversation.messages
        return Array(messages.dropFirst(sideChats[thread.sessionID]?.inherited ?? 0))
    }

    func promptImages(of thread: AgentThread, messageID: String) async throws -> [Data] {
        sessions[thread.sessionID]?.conversation.images(ofPrompt: messageID) ?? []
    }

    /// Starts a turn, or joins the one in progress as a steer, which the
    /// server takes as a prompt sent while it works.
    func sendPrompt(_ text: String, images: [URL], to thread: AgentThread) async throws {
        let session = try await session(of: thread)
        let id = thread.sessionID
        var content: [[String: Any]] = text.isEmpty ? [] : [["type": "text", "text": text]]
        var originals: [Data] = []
        var thumbnails: [Data] = []
        for url in images {
            let data = try Data(contentsOf: url)
            content.append(["type": "image", "mimeType": Self.mediaType(of: url), "data": data.base64EncodedString()])
            originals.append(data)
            if let thumbnail = TranscriptImage.thumbnail(data) { thumbnails.append(thumbnail) }
        }
        // The side chat's boundary rides as a resource, which the agent reads and the transcript leaves out.
        if unmarkedSideChats.remove(id) != nil {
            content.insert(["type": "resource", "resource": ["uri": "atrium://side-chat", "mimeType": "text/plain", "text": Self.sideChatBoundary]], at: 0)
        }
        let isSteer = session.prompts > 0
        if !session.conversation.hasPrompts, session.pendingTitle == nil { session.pendingTitle = Self.title(ofRelayed: text) }
        session.conversation.send(text, images: originals, thumbnails: thumbnails, isSteer: isSteer)
        session.prompts += 1
        if !isSteer { update(session, id: id, status: .processing) }
        onEvent?(.transcriptChanged(sessionID: id))
        Task { [weak self] in
            var status = AgentThreadStatus.done
            do {
                let reply = try await self?.connection.request("session/prompt", ["sessionId": id, "prompt": content], timeout: nil)
                if reply?["stopReason"] as? String == "cancelled" { status = .stopped }
            } catch {
                self?.log.error("An Antigravity turn failed: \(error.localizedDescription, privacy: .public)")
                status = .failed
                if session.conversation.apply(["sessionUpdate": "agent_message_chunk",
                                               "content": ["type": "text", "text": "\n\nAntigravity stopped: \(error.localizedDescription)"]]) {
                    self?.onEvent?(.transcriptChanged(sessionID: id))
                }
            }
            guard let self, self.sessions[id] === session else { return }
            session.prompts -= 1
            if session.prompts == 0 { self.update(session, id: id, status: status) }
        }
    }

    /// Antigravity names a chat by its first prompt, which for a relayed task
    /// or a fork is Atrium's framing, so such a chat is named by what it asks.
    private static func title(ofRelayed text: String) -> String? {
        let typed = ForkHandoff.request(in: text) ?? text
        guard typed != text || RelayedMessage.relay(in: typed) != nil else { return nil }
        let request = RelayedMessage.relay(in: typed)?.body ?? typed
        let title = String(request.split(separator: "\n").first ?? "").trimmingCharacters(in: .whitespaces).prefix(80)
        return title.isEmpty ? nil : String(title)
    }

    private static let sideChatBoundary = """
        This conversation is a side chat, separate from the main conversation above. Everything before this message \
        is inherited history, for reference only: don't continue, execute or complete any task, plan, tool call or \
        request from it. Only messages from here on are instructions. Answer questions and do lightweight, \
        read-only exploration. Don't modify files, git state or settings unless the user explicitly asks in this side \
        chat, and then keep the change minimal. Don't start subagents.
        """

    func interrupt(_ thread: AgentThread) async throws {
        guard sessions[thread.sessionID] != nil else { return }
        withdrawDecisions(of: thread.sessionID)
        connection.notify("session/cancel", ["sessionId": thread.sessionID])
    }

    /// Cancelling also stops the session's subagents and background tasks.
    func endBackgroundWork(_ thread: AgentThread) async throws {
        guard sessions[thread.sessionID] != nil else { return }
        connection.notify("session/cancel", ["sessionId": thread.sessionID])
    }

    func respond(to interactionID: String, with decision: AgentDecision) async throws {
        guard let pending = decisions.removeValue(forKey: interactionID) else {
            throw IntegrationError(message: "Antigravity is no longer waiting for this answer.")
        }
        connection.respond(to: pending.request, with: pending.decision.result(for: decision))
        onEvent?(.interactionResolved(id: interactionID))
        if let session = sessions[pending.sessionID], !decisions.values.contains(where: { $0.sessionID == pending.sessionID }) {
            update(session, id: pending.sessionID, status: .processing)
        }
    }

    // MARK: - Models and settings

    func models() async throws -> [AgentModel] {
        try await start()
        let reply = try await connection.setup(avoiding: Set(sessions.keys).union(opening.keys))
        let configOptions = reply["configOptions"] as? [[String: Any]] ?? []
        let modes = (reply["modes"] as? [String: Any])?["availableModes"] as? [[String: Any]] ?? []
        let models = AntigravitySettings.models(
            configOptions: configOptions, availableModels: (reply["models"] as? [String: Any])?["availableModels"] as? [[String: Any]] ?? [],
            permissionModes: AntigravitySettings.permissionModes(availableModes: modes))
        let current = AntigravitySettings(configOptions: configOptions)
        defaultSettings = TaskStartSettings(model: current.model, reasoningEffort: current.thinkingLevel, isFastMode: false)
        return models
    }

    func changeSettings(_ change: AgentSettingsChange, of thread: AgentThread) async throws {
        let session = try await session(of: thread)
        try await apply(change, to: thread.sessionID, in: session)
    }

    private func apply(_ change: AgentSettingsChange, to id: String, in session: Session) async throws {
        switch change {
        case .model(let model, let reasoningEffort):
            try await setOption("model", to: model, of: id, in: session)
            if let reasoningEffort, session.settings.thinkingLevel != nil {
                try await setOption("thought_level", to: reasoningEffort, of: id, in: session)
            }
        case .fastMode(let isOn):
            // Antigravity is never in fast mode, so turning it off changes nothing.
            guard isOn else { return }
            throw IntegrationError(message: "Antigravity has no fast mode.")
        case .permissionMode(let mode):
            try await setOption("mode", to: AntigravitySettings.mode(for: mode), of: id, in: session)
            fullAccess.set(mode == .fullAccess, for: id)
        }
        onEvent?(.threadInvalidated(sessionID: id))
    }

    private func setOption(_ option: String, to value: String, of id: String, in session: Session) async throws {
        let reply = try await connection.request("session/set_config_option", ["sessionId": id, "configId": option, "value": value])
        if let options = reply["configOptions"] as? [[String: Any]] { session.settings = AntigravitySettings(configOptions: options) }
    }

    func contextWindow(for thread: AgentThread) async -> Int? {
        if let window = sessions[thread.sessionID]?.contextUsage?.window { return window }
        return try? await session(of: thread).contextUsage?.window
    }

    func skills(in directory: String) async throws -> [AgentSkill] {
        commands[directory] ?? commands.values.first ?? []
    }

    func setEnabled(_ isEnabled: Bool) {
        self.isEnabled = isEnabled
        guard !isEnabled else { return }
        for task in opening.values { task.cancel() }
        connection.stop()
    }

    // MARK: - Server

    private func start() async throws {
        guard isEnabled else { throw IntegrationError(message: "Antigravity is turned off.") }
        try await connection.start()
    }

    /// Every open session and pending decision went with the server.
    private func closed() {
        let ids = Array(sessions.keys)
        sessions.removeAll()
        for id in decisions.keys { onEvent?(.interactionResolved(id: id)) }
        decisions.removeAll()
        for id in ids { onEvent?(.threadUpdated(sessionID: id, update: AgentThreadUpdate(status: .unknown))) }
    }

    private func receive(_ method: String, _ params: [String: Any]) {
        guard method == "session/update", let id = params["sessionId"] as? String,
              let update = params["update"] as? [String: Any], let session = sessions[id] else { return }
        switch update["sessionUpdate"] as? String {
        case "usage_update":
            guard let used = update["used"] as? Int else { return }
            session.contextUsage = AgentContextUsage(tokens: used, window: update["size"] as? Int)
            onEvent?(.threadUpdated(sessionID: id, update: AgentThreadUpdate(contextUsage: session.contextUsage)))
        case "session_info_update":
            guard let title = update["title"] as? String, !title.isEmpty else { return }
            if let pending = session.pendingTitle {
                session.pendingTitle = nil
                if pending != title {
                    Task { try? await name(id, pending) }
                    return
                }
            }
            session.title = title
            if sideChats[id] == nil { onEvent?(.threadUpdated(sessionID: id, update: AgentThreadUpdate(title: title))) }
        case "config_option_update":
            session.settings = AntigravitySettings(configOptions: update["configOptions"] as? [[String: Any]] ?? [])
            onEvent?(.threadInvalidated(sessionID: id))
        case "current_mode_update":
            session.settings.mode = update["currentModeId"] as? String
            onEvent?(.threadInvalidated(sessionID: id))
        case "available_commands_update":
            commands[session.directory] = (update["availableCommands"] as? [[String: Any]] ?? []).compactMap { command in
                guard let name = command["name"] as? String, !name.isEmpty else { return nil }
                return AgentSkill(name: name, description: command["description"] as? String ?? "")
            }
        default:
            if session.conversation.apply(update) { onEvent?(.transcriptChanged(sessionID: id)) }
        }
    }

    private func receive(_ request: AntigravityRequest) {
        guard let sessionID = request.params["sessionId"] as? String, sessions[sessionID] != nil else {
            return connection.refuse(request)
        }
        let id = "\(provider.rawValue):\(UUID().uuidString)"
        guard let (decision, interaction) = AntigravityDecision.decision(
            for: request.method, params: request.params, id: id, taskID: "\(provider.rawValue):\(sessionID)") else {
            return connection.refuse(request)
        }
        // Full Access allows tools without asking; questions still go to the user.
        if case .permission = decision, fullAccess.contains(sessionID) {
            return connection.respond(to: request, with: decision.result(for: AgentDecision(allowed: true)))
        }
        decisions[id] = Pending(request: request, decision: decision, sessionID: sessionID)
        onEvent?(.interactionRequested(interaction))
        if let session = sessions[sessionID] { update(session, id: sessionID, status: .waiting) }
    }

    /// Withdraws what the session asked, as cancelling its turn does.
    private func withdrawDecisions(of sessionID: String) {
        for (id, pending) in decisions where pending.sessionID == sessionID {
            decisions[id] = nil
            connection.respond(to: pending.request, with: pending.decision.cancellation)
            onEvent?(.interactionResolved(id: id))
        }
    }

    private func update(_ session: Session, id: String, status: AgentThreadStatus) {
        guard session.status != status else { return }
        let startsTurn = status == .processing && !session.status.isWorking
        session.status = status
        onEvent?(.threadUpdated(sessionID: id, update: AgentThreadUpdate(status: status, updatedAt: .now, startsNewTurn: startsTurn)))
    }

    // MARK: - Helpers

    private static func mediaType(of url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": "image/png"
        case "gif": "image/gif"
        case "webp": "image/webp"
        default: "image/jpeg"
        }
    }
}

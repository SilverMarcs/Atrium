import AppKit
import AtriumProtocol
import Foundation
import OSLog

/// Jcode through its harness API. Jcode is the agent: its server owns the
/// sessions, tools, model connections and logins, and Atrium only attaches
/// to the sessions it shows, one connection each, letting them go when a chat
/// settles so Jcode's server can idle out.
@MainActor
final class JcodeAgentAdapter: AgentProviderAdapter {
    let provider = AgentProvider.jcode
    /// Jcode keeps no read state, and archives rather than deletes chats.
    let capabilities: AgentCapabilities = [.forkThread, .deleteThread, .renameThread, .selectModel, .editMessage]
    var onEvent: ((AgentEvent) -> Void)?
    private(set) var defaultSettings: TaskStartSettings?

    private let bridge = JcodeBridge()
    private let instructions: ChatInstructions
    private var sessions: [String: Session] = [:]
    private var opening: [String: Task<Session, Error>] = [:]
    /// What Jcode last reported of each session, kept after it's let go.
    private var reported: [String: Reported] = [:]
    private var cachedModels: [AgentModel] = []
    private var isEnabled = true

    private final class Session {
        let connection: JcodeConnection
        let conversation = JcodeLiveConversation()
        var status: AgentThreadStatus = .idle
        var reloading: Task<Void, Never>?
        var reloadID: UUID?
        /// A name to give the session once its first turn has saved it.
        var pendingTitle: String?
        init(connection: JcodeConnection) { self.connection = connection }
    }

    private struct Reported {
        var model: String?
        var reasoningEffort: String?
        var provider: String?
        var isFastMode: Bool?
        var contextUsage: AgentContextUsage?
        var contextWindow: Int?
    }

    init(instructions: ChatInstructions) {
        self.instructions = instructions
        // The bridge is Atrium's child, so it goes when Atrium does; Jcode's server idles out by itself.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.bridge.stop() }
        }
    }

    // MARK: - Listing

    func listThreads() async throws -> [AgentThread] {
        let connection = try await bridge.connect()
        defer { connection.close() }
        let reply = try await connection.request(["req": "list_sessions"])
        return (reply["sessions"] as? [[String: Any]] ?? []).compactMap(thread)
    }

    func readThread(_ sessionID: String) async throws -> AgentThread? {
        try await listThreads().first { $0.sessionID == sessionID }
    }

    private func thread(_ info: [String: Any]) -> AgentThread? {
        guard let id = info["session_id"] as? String else { return nil }
        let title = (info["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let parent = info["parent_session_id"] as? String
        let label = (info["agent_label"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let updated = (info["updated_at_ms"] as? Double ?? info["last_active_at_ms"] as? Double).map { $0 / 1000 }
        var thread = AgentThread(
            sessionID: id, provider: .jcode,
            title: !title.isEmpty ? title : !label.isEmpty ? label : "New Jcode chat",
            directory: info["working_dir"] as? String ?? URL.homeDirectory.path(percentEncoded: false),
            updatedAt: updated.map(Date.init(timeIntervalSince1970:)) ?? .now,
            status: sessions[id]?.status ?? (info["status"] as? String == "running" ? .processing : .unknown),
            isMainTask: parent == nil, hasProviderTitle: !title.isEmpty || parent != nil,
            parentSessionID: parent
        )
        apply(reported[id], to: &thread)
        return thread
    }

    private func apply(_ reported: Reported?, to thread: inout AgentThread) {
        thread.model = reported?.model ?? thread.model
        thread.reasoningEffort = reported?.reasoningEffort ?? thread.reasoningEffort
        thread.isFastMode = reported?.isFastMode ?? thread.isFastMode
        thread.contextUsage = reported?.contextUsage
        thread.permissionMode = .fullAccess
    }

    // MARK: - Conversations

    func openConversation(_ thread: AgentThread) async throws {
        _ = try await session(of: thread)
    }

    private func session(of thread: AgentThread) async throws -> Session {
        guard isEnabled else { throw IntegrationError(message: "Jcode is turned off.") }
        if let session = sessions[thread.sessionID] { return session }
        if let task = opening[thread.sessionID] { return try await task.value }
        let id = thread.sessionID
        let task = Task { () throws -> Session in
            let connection = try await bridge.connect()
            let session = Session(connection: connection)
            connect(session, id: id)
            do {
                _ = try await connection.request(["req": "attach_session", "session_id": id])
                try await connection.request(["req": "get_history", "session_id": id], timeout: .seconds(60),
                                             receivingReply: { session.conversation.restore($0) })
            } catch {
                connection.close()
                throw error
            }
            sessions[id] = session
            return session
        }
        opening[id] = task
        defer { opening[id] = nil }
        let session = try await task.value
        onEvent?(.threadUpdated(sessionID: id, update: AgentThreadUpdate(status: session.status)))
        await refreshRuntime(of: id, on: session)
        return session
    }

    private func connect(_ session: Session, id: String) {
        session.connection.onEvent = { [weak self, weak session] event in
            guard let self, let session else { return }
            self.receive(event, in: session, id: id)
        }
        session.connection.onClose = { [weak self, weak session] _ in
            guard let self, let session, self.sessions[id] === session else { return }
            self.sessions[id] = nil
            self.onEvent?(.threadUpdated(sessionID: id, update: AgentThreadUpdate(status: .unknown)))
        }
    }

    private func receive(_ event: [String: Any], in session: Session, id: String) {
        if let sessionID = event["session_id"] as? String, !sessionID.isEmpty, sessionID != id { return }
        switch event["ev"] as? String {
        case "session_status":
            let status: AgentThreadStatus? = switch event["status"] as? String {
            case "running": .processing
            // A turn ends with `turn_done`, which reads the saved reply first.
            case "idle": session.status == .processing ? nil : .idle
            case "cancelled": .idle
            default: nil
            }
            if let status { update(session, id: id, status: status) }
        case "turn_stopped":
            if ["failure", "crash", "limit_reached", "provider_guardrail"].contains(event["reason"] as? String ?? "") {
                Logger(subsystem: "Atrium", category: "Jcode").error("A Jcode turn stopped: \(event["message"] as? String ?? "", privacy: .public)")
                update(session, id: id, status: .failed)
            }
        case "turn_done":
            // The saved reply replaces what streamed before the turn reads as over,
            // as other providers' final items do, so clients settle on the saved one.
            reload(session, id: id) { [weak self] in
                if session.status != .failed { self?.update(session, id: id, status: .idle) }
                if let title = session.pendingTitle {
                    session.pendingTitle = nil
                    Task { _ = try? await session.connection.request(["req": "rename_session", "session_id": id, "title": title]) }
                }
            }
        case "model_info":
            var info = reported[id] ?? Reported()
            info.model = event["model"] as? String ?? info.model
            info.reasoningEffort = event["reasoning_effort"] as? String ?? info.reasoningEffort
            info.provider = event["provider"] as? String ?? info.provider
            reported[id] = info
            onEvent?(.threadInvalidated(sessionID: id))
        case "token_usage":
            var info = reported[id] ?? Reported()
            info.contextUsage = Self.contextUsage(event, provider: info.provider, window: info.contextWindow)
            reported[id] = info
            onEvent?(.threadUpdated(sessionID: id, update: AgentThreadUpdate(contextUsage: info.contextUsage)))
        case "session_renamed":
            if let title = event["display_title"] as? String ?? event["title"] as? String {
                onEvent?(.threadUpdated(sessionID: id, update: AgentThreadUpdate(title: title)))
            }
        default:
            if session.conversation.apply(event) { onEvent?(.transcriptChanged(sessionID: id)) }
        }
    }

    private func update(_ session: Session, id: String, status: AgentThreadStatus) {
        guard session.status != status else { return }
        let startsTurn = status == .processing && session.status != .processing
        session.status = status
        var update = AgentThreadUpdate(status: status, updatedAt: .now)
        update.startsNewTurn = startsTurn
        onEvent?(.threadUpdated(sessionID: id, update: update))
    }

    /// Reads the saved history again once a turn ends, which replaces what it streamed.
    private func reload(_ session: Session, id: String, then finish: (() -> Void)? = nil) {
        session.reloading?.cancel()
        let reloadID = UUID()
        session.reloadID = reloadID
        session.reloading = Task { [weak self, weak session] in
            guard let session else { return }
            _ = try? await session.connection.request(["req": "get_history", "session_id": id], timeout: .seconds(60), receivingReply: { [weak self, weak session] history in
                guard let session, session.reloadID == reloadID, session.reloading?.isCancelled == false else { return }
                session.conversation.restore(history)
                self?.onEvent?(.transcriptChanged(sessionID: id))
            })
            guard !Task.isCancelled else { return }
            finish?()
        }
    }

    /// The model, effort, fast mode and context window the session runs with.
    private func refreshRuntime(of id: String, on session: Session) async {
        var info = reported[id] ?? Reported()
        if let reply = try? await session.connection.request(["req": "runtime_command", "session_id": id, "command": "info"]),
           let data = reply["data"] as? [String: Any] {
            info.model = data["model"] as? String ?? info.model
            info.reasoningEffort = data["reasoning_effort"] as? String ?? info.reasoningEffort
            info.provider = data["provider"] as? String ?? info.provider
            info.contextWindow = data["context_window"] as? Int ?? info.contextWindow
            info.isFastMode = info.provider == "OpenAI" ? data["service_tier"] as? String == "priority" : nil
        }
        reported[id] = info
        onEvent?(.threadInvalidated(sessionID: id))
    }

    func transcript(for thread: AgentThread) async throws -> [TranscriptMessage] {
        // A swarm agent belongs to the agent that started it, so it's read without attaching.
        if thread.isSubagent {
            let connection = try await bridge.connect()
            defer { connection.close() }
            let reply = try await connection.request(["req": "peek_session", "session_id": thread.sessionID, "limit": 5000])
            return JcodeTranscript.messages(from: reply["messages"] as? [[String: Any]] ?? [])
        }
        return try await session(of: thread).conversation.messages
    }

    // MARK: - Prompts

    /// Starts a turn, or adds to the one in progress the way Jcode's soft interrupt does.
    func sendPrompt(_ text: String, images: [URL], to thread: AgentThread) async throws {
        let session = try await session(of: thread)
        var attachments: [[String]] = []
        var previews: [Data] = []
        for url in images {
            let data = try Data(contentsOf: url)
            attachments.append([Self.mediaType(of: url), data.base64EncodedString()])
            if let preview = TranscriptImage.thumbnail(data) { previews.append(preview) }
        }
        if session.status == .processing {
            var request: [String: Any] = ["req": "soft_interrupt", "session_id": thread.sessionID, "content": text]
            if !attachments.isEmpty { request["images"] = attachments }
            try await session.connection.request(request)
            session.conversation.send(text, images: previews, isSteer: true)
        } else {
            var request: [String: Any] = ["req": "send_message", "session_id": thread.sessionID, "content": text]
            if !attachments.isEmpty { request["images"] = attachments }
            // Atrium's instructions ride in the first turn as a hidden reminder, which
            // Jcode keeps in the conversation without changing its system prompt.
            let isFirst = !session.conversation.hasPrompts
            if isFirst { request["system_reminder"] = instructionText(for: thread) }
            session.conversation.send(text, images: previews, isSteer: false)
            update(session, id: thread.sessionID, status: .processing)
            onEvent?(.transcriptChanged(sessionID: thread.sessionID))
            do {
                try await session.connection.request(request, timeout: .seconds(60),
                                                     acknowledgedBy: { $0["ev"] as? String == "message_accepted" })
            } catch {
                reload(session, id: thread.sessionID)
                update(session, id: thread.sessionID, status: .idle)
                throw error
            }
            // Jcode titles a chat by its first prompt, which for a relayed task or a
            // fork is Atrium's framing, so it's titled by what it asks instead.
            let typed = ForkHandoff.request(in: text) ?? text
            if isFirst, session.pendingTitle == nil, typed != text || RelayedMessage.relay(in: typed) != nil {
                let request = RelayedMessage.relay(in: typed)?.body ?? typed
                let title = String(request.split(separator: "\n").first ?? "").trimmingCharacters(in: .whitespaces).prefix(80)
                // Jcode keeps a name given before the turn saves the session only in memory.
                if !title.isEmpty { session.pendingTitle = String(title) }
            }
        }
        onEvent?(.transcriptChanged(sessionID: thread.sessionID))
    }

    private func instructionText(for thread: AgentThread) -> String {
        let blocks = instructions.blocks(for: thread.id)
        var text = AgentInstructions.text(blocks)
        // Jcode's server may have been started by its terminal app, without
        // Atrium's PATH, and its API can't give a session one.
        if blocks.contains(.orchestrator) {
            let helpers = Bundle.main.bundleURL.appending(path: "Contents/Helpers/atrium").path(percentEncoded: false)
            text += "\n\nIf `atrium` isn't on your PATH, run it as `\(helpers)`."
        }
        return text
    }

    func promptImages(of thread: AgentThread, messageID: String) async throws -> [Data] {
        let target = Self.editTarget(messageID)
        return try await session(of: thread).conversation.images(ofPrompt: target)
    }

    func rewind(_ thread: AgentThread, before messageID: String) async throws -> [TranscriptMessage] {
        let session = try await session(of: thread)
        try await rewind(thread.sessionID, before: messageID, on: session.connection)
        try await session.connection.request(["req": "get_history", "session_id": thread.sessionID], timeout: .seconds(60),
                                             receivingReply: { session.conversation.restore($0) })
        onEvent?(.transcriptChanged(sessionID: thread.sessionID))
        return session.conversation.messages
    }

    /// Keeps the rows before a prompt, as its edit target places it.
    private func rewind(_ sessionID: String, before editTarget: String, on connection: JcodeConnection) async throws {
        guard let ordinal = Int(Self.editTarget(editTarget)), ordinal > 0 else {
            throw IntegrationError(message: "That message can’t be edited.")
        }
        if ordinal == 1 {
            try await connection.request(["req": "clear", "session_id": sessionID])
        } else {
            try await connection.request(["req": "rewind", "session_id": sessionID, "message_index": ordinal - 1])
        }
    }

    func interrupt(_ thread: AgentThread) async throws {
        guard let session = sessions[thread.sessionID] else { return }
        try await session.connection.request(["req": "cancel", "session_id": thread.sessionID])
    }

    // MARK: - Threads

    func createThread(directory: String, settings: TaskStartSettings?, title: String?, inNewWorktree: Bool) async throws -> AgentThread {
        let worktree = inNewWorktree ? try await Self.newWorktree(of: directory) : nil
        let connection = try await bridge.connect()
        let session = Session(connection: connection)
        let reply: [String: Any]
        do {
            reply = try await connection.request(["req": "create_session", "working_dir": worktree?.path(percentEncoded: false) ?? directory])
        } catch {
            connection.close()
            if let worktree { await Self.removeWorktree(worktree, of: directory) }
            throw error
        }
        guard let info = reply["session"] as? [String: Any], let id = info["session_id"] as? String else {
            connection.close()
            throw IntegrationError(message: "Jcode didn’t start a session.")
        }
        connect(session, id: id)
        sessions[id] = session
        instructions.record(instructions.forNewChat, for: "jcode:\(id)")
        if let model = settings?.model {
            try await connection.request(["req": "set_model", "session_id": id, "model": model])
        }
        if let effort = settings?.reasoningEffort {
            try await connection.request(["req": "set_reasoning_effort", "session_id": id, "effort": effort])
        }
        if let isFastMode = settings?.isFastMode {
            _ = try? await connection.request(["req": "runtime_command", "session_id": id, "command": "fast", "args": [isFastMode ? "on" : "off"]])
        }
        // Jcode saves a new session with its first turn, and a name given before then with it.
        session.pendingTitle = title
        await refreshRuntime(of: id, on: session)
        guard var thread = thread(info) else { throw IntegrationError(message: "Jcode didn’t start a session.") }
        thread.status = .idle
        if let title {
            thread.title = title
            thread.hasProviderTitle = true
        }
        return thread
    }

    /// A worktree for a new chat, as Codex makes one, since Jcode has none of its own:
    /// in `worktrees/<four hex digits>/<repository>` of Jcode's home, detached at the checked-out commit.
    private static func newWorktree(of directory: String) async throws -> URL {
        let repository = URL(filePath: directory, directoryHint: .isDirectory)
        let home = IntegrationProcess.environment["JCODE_HOME"].flatMap { $0.isEmpty ? nil : URL(filePath: $0) }
            ?? URL.homeDirectory.appending(path: ".jcode")
        var bucket: URL
        repeat {
            bucket = home.appending(path: "worktrees/\(UUID().uuidString.prefix(4).lowercased())", directoryHint: .isDirectory)
        } while FileManager.default.fileExists(atPath: bucket.path)
        try FileManager.default.createDirectory(at: bucket, withIntermediateDirectories: true)
        let worktree = bucket.appending(path: repository.lastPathComponent, directoryHint: .isDirectory)
        do {
            try await GitRepository.shared.addDetachedWorktree(at: worktree, from: repository)
        } catch {
            try? FileManager.default.removeItem(at: bucket)
            throw error
        }
        return worktree
    }

    private static func removeWorktree(_ worktree: URL, of directory: String) async {
        if (try? await GitRepository.shared.deleteWorktree(at: worktree, in: URL(filePath: directory, directoryHint: .isDirectory))) != nil {
            try? FileManager.default.removeItem(at: worktree.deletingLastPathComponent())
        }
    }

    /// Jcode copies the whole conversation; a fork before a prompt is then rewound to it.
    func forkThread(_ thread: AgentThread, before messageID: String?) async throws -> AgentThread {
        let source = try await session(of: thread)
        let reply = try await source.connection.request(["req": "fork_session", "session_id": thread.sessionID])
        guard let info = reply["session"] as? [String: Any], let id = info["session_id"] as? String else {
            throw IntegrationError(message: "Jcode didn’t fork the session.")
        }
        instructions.record(instructions.blocks(for: thread.id), for: "jcode:\(id)")
        reported[id] = reported[thread.sessionID]
        let connection = try await bridge.connect()
        let session = Session(connection: connection)
        connect(session, id: id)
        do {
            _ = try await connection.request(["req": "attach_session", "session_id": id])
            if let messageID { try await rewind(id, before: messageID, on: connection) }
            _ = try? await connection.request(["req": "rename_session", "session_id": id, "title": thread.forkTitle])
            try await connection.request(["req": "get_history", "session_id": id], timeout: .seconds(60),
                                         receivingReply: { session.conversation.restore($0) })
        } catch {
            connection.close()
            throw error
        }
        sessions[id] = session
        guard var fork = self.thread(info) else { throw IntegrationError(message: "Jcode didn’t fork the session.") }
        fork.status = .idle
        fork.title = thread.forkTitle
        fork.hasProviderTitle = true
        onEvent?(.listInvalidated)
        return fork
    }

    func renameThread(_ thread: AgentThread, to title: String) async throws {
        try await session(of: thread).connection.request(["req": "rename_session", "session_id": thread.sessionID, "title": title])
    }

    /// Jcode can't delete a session: archiving hides it from every list and keeps it restorable.
    func deleteThread(_ thread: AgentThread) async throws {
        try await stopThread(thread)
        let connection = try await bridge.connect()
        defer { connection.close() }
        try await connection.request(["req": "archive_session", "session_id": thread.sessionID])
        onEvent?(.threadDeleted(sessionID: thread.sessionID))
        onEvent?(.listInvalidated)
    }

    /// Lets the session go: a turn in progress keeps running in Jcode's server.
    func stopThread(_ thread: AgentThread) async throws {
        opening[thread.sessionID]?.cancel()
        guard let session = sessions.removeValue(forKey: thread.sessionID) else { return }
        session.reloading?.cancel()
        _ = try? await session.connection.request(["req": "detach_session", "session_id": thread.sessionID], timeout: .seconds(5))
        session.connection.close()
        onEvent?(.threadUpdated(sessionID: thread.sessionID, update: AgentThreadUpdate(status: .unknown)))
    }

    func prepareLaunch(for thread: AgentThread) async throws -> AgentLaunch {
        AgentLaunch(executable: "jcode", arguments: ["--cwd", thread.directory, "--resume", thread.sessionID])
    }

    // MARK: - Models

    func models() async throws -> [AgentModel] {
        // Jcode lists its routes for a session, so a session nobody prompts is
        // made to ask; Jcode doesn't keep one without messages.
        let connection = try await bridge.connect()
        defer { connection.close() }
        let created = try await connection.request(["req": "create_session", "working_dir": URL.homeDirectory.path(percentEncoded: false)])
        guard let id = (created["session"] as? [String: Any])?["session_id"] as? String else {
            throw IntegrationError(message: "Jcode didn’t list its models.")
        }
        let info = try await connection.request(["req": "get_runtime_info", "session_id": id])
        cachedModels = JcodeModels.models(fromRoutes: info["routes"] as? [[String: Any]] ?? [])
        let fast = try? await connection.request(["req": "runtime_command", "session_id": id, "command": "fast", "args": ["status"]])
        let model = info["model"] as? String
        let available = cachedModels.model(running: model)
        defaultSettings = TaskStartSettings(
            model: available?.id ?? cachedModels.first?.id,
            reasoningEffort: available == nil ? nil : info["reasoning_effort"] as? String,
            isFastMode: available?.supportsFastMode == true ? (fast?["data"] as? [String: Any])?["service_tier"] as? String == "priority" : false)
        _ = try? await connection.request(["req": "detach_session", "session_id": id], timeout: .seconds(5))
        return cachedModels
    }

    func changeSettings(_ change: AgentSettingsChange, of thread: AgentThread) async throws {
        let session = try await session(of: thread)
        let id = thread.sessionID
        switch change {
        case .model(let model, let reasoningEffort):
            try await session.connection.request(["req": "set_model", "session_id": id, "model": model])
            if let reasoningEffort {
                try await session.connection.request(["req": "set_reasoning_effort", "session_id": id, "effort": reasoningEffort])
            }
        case .fastMode(let isOn):
            try await session.connection.request(["req": "runtime_command", "session_id": id, "command": "fast", "args": [isOn ? "on" : "off"]])
        case .permissionMode(let mode):
            guard mode == .fullAccess else {
                throw IntegrationError(message: "Jcode runs its tools without asking, so its chats always have full access.")
            }
        }
        await refreshRuntime(of: id, on: session)
    }

    func contextWindow(for thread: AgentThread) async -> Int? {
        if let window = reported[thread.sessionID]?.contextWindow { return window }
        guard let session = try? await session(of: thread) else { return nil }
        await refreshRuntime(of: thread.sessionID, on: session)
        return reported[thread.sessionID]?.contextWindow
    }

    func setEnabled(_ isEnabled: Bool) {
        self.isEnabled = isEnabled
        guard !isEnabled else { return }
        for task in opening.values { task.cancel() }
        for session in sessions.values { session.connection.close() }
        sessions.removeAll()
        bridge.stop()
    }

    // MARK: - Helpers

    /// How full the context is, from the latest request's counts. OpenAI's input
    /// includes the cached share; Anthropic's leaves it out.
    private static func contextUsage(_ event: [String: Any], provider: String?, window: Int?) -> AgentContextUsage? {
        guard let input = event["input"] as? Int else { return nil }
        let cached = (event["cache_read_input"] as? Int ?? 0) + (event["cache_creation_input"] as? Int ?? 0)
        let tokens = provider == "OpenAI" ? input : input + cached
        return AgentContextUsage(tokens: tokens, window: event["effective_budget"] as? Int ?? window)
    }

    /// A prompt's edit target, its place among the rows, from its message ID or the target itself.
    private static func editTarget(_ messageID: String) -> String {
        guard messageID.hasPrefix("u") else { return messageID }
        return String(messageID.dropFirst().prefix { $0 != "." })
    }

    private static func mediaType(of url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": "image/png"
        case "gif": "image/gif"
        case "webp": "image/webp"
        default: "image/jpeg"
        }
    }
}

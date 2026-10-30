import AtriumProtocol
import Foundation
import OSLog

@MainActor
final class ClaudeAgentAdapter: AgentProviderAdapter {
    let provider = AgentProvider.claude
    let capabilities: AgentCapabilities = [.forkThread, .deleteThread, .renameThread, .prompt, .selectModel, .editMessage]
    private(set) var defaultSettings: TaskStartSettings?
    var onEvent: ((AgentEvent) -> Void)?
    private let history: ClaudeSessionHistory
    private let configDirectory: URL
    /// Claude's global config, where it caches account state such as whether fast mode is allowed.
    private let globalConfigFile: URL
    private var backgroundIDs: [String: String] = [:]
    private var backgroundSessions: [String: ClaudeBackgroundSession] = [:]
    private var statusRevision = 0
    private var backgroundListTask: Task<[ClaudeBackgroundSession], Error>?
    private let daemon: ClaudeDaemonClient
    private let hooks: ClaudeHookServer
    private var live: [String: ClaudeLiveTranscript] = [:]
    private var transcriptLoads: [String: Task<[TranscriptMessage], Error>] = [:]
    private var subscriptions: [String: UnixJSONConnection] = [:]
    private var subscriptionTasks: [String: Task<Void, Never>] = [:]
    private var decisions: [String: ClaudePendingDecision] = [:]
    private var isEnabled = true
    private var historyWatcher: FileSystemWatcher?
    private var outgoing: [String: [ClaudeOutgoingPrompt]] = [:]
    private var liveStatuses: [String: AgentThreadStatus] = [:]
    private struct UnsavedTurn: Equatable {
        /// The latest Stop record saved when the turn ended, from an earlier stop.
        let previousStop: String?
    }
    /// Turns whose Stop hook ran before Claude saved them, keyed by session.
    /// Their chat stays as the hooks reported it until history has all of it.
    private var unsavedTurns: [String: UnsavedTurn] = [:]
    /// Settings typed into each thread's terminal that its transcript doesn't show yet.
    private var settingsOverrides: [String: ClaudeSettingsOverride] = [:]

    init(configDirectory: URL? = nil) {
        hooks = ClaudeHookServer()
        let configured = IntegrationProcess.environment["CLAUDE_CONFIG_DIR"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let directory = configDirectory ?? configured
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
        self.configDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        daemon = ClaudeDaemonClient(configDirectory: self.configDirectory)
        history = ClaudeSessionHistory(configDirectory: self.configDirectory)
        // The global config sits beside the default config directory, or inside a custom one.
        globalConfigFile = (configDirectory ?? configured)?.appending(path: ".claude.json")
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude.json")
        hooks.onEvent = { [weak self] body in
            guard let self, self.isEnabled else { return Data("{}".utf8) }
            return try await self.receiveHook(body)
        }
    }

    func listThreads() async throws -> [AgentThread] {
        try watchHistory()
        try await refreshBackgroundSessions()
        let saved = try await history.listThreads()
        var threads = Dictionary(saved.map { ($0.sessionID, $0) }, uniquingKeysWith: { _, new in new })
        // A job without saved history is shown only while it runs: an exited one is a draft
        // that never got a prompt or a thread whose history was deleted.
        for session in backgroundSessions.values where session.isRunning {
            guard let thread = session.thread, threads[thread.sessionID] == nil else { continue }
            threads[thread.sessionID] = thread
        }
        return AgentThread.unique(threads.values.map(withStatus))
    }

    func readThread(_ id: String) async throws -> AgentThread? {
        try await (history.readThread(id) ?? backgroundSessions[id]?.thread).map(withStatus)
    }

    private func watchHistory() throws {
        guard historyWatcher == nil else { return }
        let projects = configDirectory.appending(path: "projects")
        try FileManager.default.createDirectory(at: projects, withIntermediateDirectories: true)
        historyWatcher = FileSystemWatcher(url: projects, latency: 0.3, ignoredSubstrings: [], onPathsChanged: { [weak self] paths in
            Task { @MainActor [weak self] in
                guard let self, self.isEnabled else { return }
                for path in paths {
                    let url = URL(fileURLWithPath: path)
                    let id = url.lastPathComponent == "custom-title.json"
                        ? url.deletingLastPathComponent().lastPathComponent : url.deletingPathExtension().lastPathComponent
                    guard UUID(uuidString: id) != nil else { continue }
                    self.onEvent?(.threadInvalidated(sessionID: id))
                    if self.unsavedTurns[id] != nil { await self.loadSavedTurn(id) }
                }
            }
        })
    }

    func transcript(for thread: AgentThread) async throws -> [TranscriptMessage] {
        if let live = live[thread.sessionID] { return live.messages }
        return try await savedTranscript(thread.sessionID)
    }

    /// Claude writes a session's file with its first prompt, so only a session
    /// that hasn't had one yet may be missing it.
    private func savedTranscript(_ sessionID: String) async throws -> [TranscriptMessage] {
        if let messages = try await history.transcript(sessionID) { return messages }
        guard backgroundSessions[sessionID] != nil else {
            throw IntegrationError(message: "Claude's history for this chat could not be found.")
        }
        return []
    }

    /// Claude saves a turn's records in batches, so its last ones can reach the file after the Stop hook.
    /// The Stop record it saves once the hooks finish marks the whole turn as saved.
    private func loadSavedTurn(_ sessionID: String) async {
        guard let turn = unsavedTurns[sessionID],
              let saved = try? await history.transcriptWithStop(sessionID),
              let stop = saved.stop, stop != turn.previousStop, !saved.messages.isEmpty,
              unsavedTurns[sessionID] == turn else { return }
        unsavedTurns[sessionID] = nil
        // History also restores mid-turn prompts, which are saved as queued attachments without a prompt hook.
        live[sessionID] = ClaudeLiveTranscript(history: saved.messages)
        onEvent?(.transcriptChanged(sessionID: sessionID))
    }

    func openConversation(_ thread: AgentThread) async throws {
        guard UUID(uuidString: thread.sessionID) != nil else { throw IntegrationError(message: "Invalid Claude session identifier.") }
        _ = try await hooks.start()
        let sessions = try await listBackgroundSessions()
        let session: ClaudeBackgroundSession
        if let existing = sessions.first(where: { $0.kind == "background" && $0.sessionID == thread.sessionID && $0.isRunning }) {
            session = existing
        } else {
            session = try await startBackgroundSession(directory: thread.directory, resuming: thread.sessionID)
        }
        guard let id = session.id else { throw IntegrationError(message: "Claude did not provide a background identifier.") }
        backgroundIDs[thread.sessionID] = id
        backgroundSessions[thread.sessionID] = session
        if try await hasHooks(jobID: id) {
            liveStatuses[thread.sessionID] = session.threadStatus
            _ = try await liveTranscript(thread.sessionID)
        }
        subscribe(sessionID: thread.sessionID, jobID: id)
    }

    func sendPrompt(_ text: String, images: [URL], to thread: AgentThread) async throws {
        try await openConversation(thread)
        guard let id = backgroundIDs[thread.sessionID] else { throw IntegrationError(message: "Claude is not connected.") }
        guard try await hasHooks(jobID: id) else {
            throw IntegrationError(message: "This background session was started outside Atrium without chat hooks. Open Terminal to continue it.")
        }
        let references = images.map { "@\"" + $0.path.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") + "\"" }
        let prompt = (references + (text.isEmpty ? [] : [text])).joined(separator: "\n")
        let outgoingPrompt = ClaudeOutgoingPrompt(wireText: prompt, displayText: text, images: images.compactMap { TranscriptImage.thumbnail(at: $0) })
        let isSteering = withStatus(thread).status == .processing
        outgoing[thread.sessionID, default: []].append(outgoingPrompt)
        // Never retry an acknowledged write: a failed acknowledgement can still mean
        // Claude queued the prompt. Let the user decide whether to resend.
        do { try await daemon.reply(prompt, jobID: id) }
        catch {
            outgoing[thread.sessionID]?.removeAll { $0.id == outgoingPrompt.id }
            throw error
        }
        // Claude holds a prompt sent mid-turn until its running tools finish. Steer with it now;
        // if that fails, the prompt is still queued and arrives when they do.
        if isSteering {
            do { try await daemon.sendQueuedNow(jobID: id) }
            catch { Logger(subsystem: "Atrium", category: "Claude").debug("Steering failed: \(error.localizedDescription)") }
        }
        onEvent?(.threadUpdated(sessionID: thread.sessionID, update: AgentThreadUpdate(status: .processing, updatedAt: .now)))
    }

    func rewind(_ thread: AgentThread, before messageID: String) async throws -> (messages: [TranscriptMessage], images: [Data]) {
        guard UUID(uuidString: messageID) != nil,
              let messages = try await history.transcript(thread.sessionID),
              messages.contains(where: { $0.editTarget == messageID }) else {
            throw IntegrationError(message: "That message is no longer in the conversation. Reload it and try again.")
        }
        let sessions = try await listBackgroundSessions()
        guard !sessions.contains(where: {
            $0.sessionID == thread.sessionID && $0.isRunning && ($0.threadStatus == .processing || $0.threadStatus == .waiting)
        }) else {
            throw IntegrationError(message: "Wait for Claude to finish or stop it before editing a message.")
        }
        let images = try await history.promptImages(thread.sessionID, messageID: messageID)
        // The daemon's interactive workers do not accept SDK control requests.
        // Release this session's writer, let the CLI persist its own rewind,
        // and let the normal next send resume the same background job.
        try await stopThread(thread)
        let requests: [[String: Any]] = [
            ["type": "control_request", "request_id": "initialize", "request": ["subtype": "initialize"]],
            ["type": "control_request", "request_id": "rewind", "request": [
                "subtype": "rewind_conversation", "target_message_uuid": messageID,
                "last_seen_user_message_uuid": messages.last(where: { $0.role == .user })?.id ?? messageID
            ]]
        ]
        var input = Data()
        for request in requests {
            input.append(try JSONSerialization.data(withJSONObject: request))
            input.append(10)
        }
        let output = try await IntegrationProcess.run("claude", arguments: [
            "-p", "--resume", thread.sessionID, "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"
        ], directory: thread.directory, input: input, timeout: .seconds(60))
        let response = output.split(separator: 10).compactMap {
            (try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])?["response"] as? [String: Any]
        }.first { $0["request_id"] as? String == "rewind" }
        let result = response?["response"] as? [String: Any]
        guard result?["rewound"] as? Bool == true else {
            throw IntegrationError(message: response?["error"] as? String ?? result?["reason"] as? String ?? "Claude could not rewind this message.")
        }
        let retained = try await savedTranscript(thread.sessionID)
        live[thread.sessionID] = ClaudeLiveTranscript(history: retained)
        onEvent?(.transcriptChanged(sessionID: thread.sessionID))
        onEvent?(.threadInvalidated(sessionID: thread.sessionID))
        return (retained, images)
    }

    func interrupt(_ thread: AgentThread) async throws {
        try await openConversation(thread)
        guard let id = backgroundIDs[thread.sessionID] else { return }
        try await daemon.interrupt(jobID: id)
        resolveDecisions(sessionID: thread.sessionID)
        onEvent?(.threadUpdated(sessionID: thread.sessionID, update: AgentThreadUpdate(status: .stopped)))
    }

    func changeSettings(_ change: AgentSettingsChange, of thread: AgentThread) async throws {
        try await openConversation(thread)
        guard let id = backgroundIDs[thread.sessionID] else { return }
        for command in try terminalCommands(for: change, of: thread) { try await daemon.reply(command, jobID: id) }
        onEvent?(.threadInvalidated(sessionID: thread.sessionID))
    }

    /// Lists models the way the SDK does: Claude answers an `initialize` request
    /// with its picker's rows, without starting a conversation.
    func models() async throws -> [AgentModel] {
        let request = #"{"type":"control_request","request_id":"atrium","request":{"subtype":"initialize"}}"# + "\n"
        let output = try await IntegrationProcess.run("claude", arguments: [
            "-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--no-session-persistence"
        ], input: Data(request.utf8), timeout: .seconds(30))
        let response = output.split(separator: UInt8(ascii: "\n")).lazy
            .compactMap { try? JSONDecoder().decode(ClaudeInitializeResponse.self, from: Data($0)) }
            .first { $0.type == "control_response" }
        guard let options = response?.models else {
            throw IntegrationError(message: "Claude did not list its models.")
        }
        let file = globalConfigFile
        let allowsFastMode = await Task.detached { Self.organizationAllowsFastMode(configFile: file) }.value
        let environment = IntegrationProcess.environment
        let configDirectory = self.configDirectory
        let configured = await Task.detached { () -> TaskStartSettings in
            let data = try? Data(contentsOf: configDirectory.appending(path: "settings.json"))
            let settings = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            return TaskStartSettings(
                model: environment["ANTHROPIC_MODEL"] ?? settings["model"] as? String ?? environment["ANTHROPIC_DEFAULT_MODEL"],
                reasoningEffort: environment["CLAUDE_CODE_EFFORT_LEVEL"] ?? settings["effortLevel"] as? String,
                isFastMode: settings["fastMode"] as? Bool
            )
        }.value
        let fallback = options.first { $0.value == "default" }?.resolvedModel
        defaultSettings = TaskStartSettings(
            model: configured.model == "default" ? fallback : configured.model ?? fallback,
            reasoningEffort: configured.reasoningEffort,
            isFastMode: allowsFastMode && configured.isFastMode == true
        )
        // "default" stands for one of the other rows, which tasks report running instead.
        return options.filter { $0.value != "default" }.map { $0.model(allowingFastMode: allowsFastMode) }
    }

    /// Whether the account's organization allows fast mode, as Claude last checked.
    nonisolated private static func organizationAllowsFastMode(configFile: URL) -> Bool {
        guard let data = try? Data(contentsOf: configFile),
              let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return config["penguinModeOrgEnabled"] as? Bool == true
    }

    func terminalCommands(for change: AgentSettingsChange, of thread: AgentThread) throws -> [String] {
        var override = settingsOverrides[thread.sessionID] ?? ClaudeSettingsOverride(reportedBy: thread)
        override.append(change)
        settingsOverrides[thread.sessionID] = override
        switch change {
        case .model(let model, let reasoningEffort):
            // The model goes first, as switching models restores that model's own effort.
            return ["/model \(model)"] + (reasoningEffort.map { ["/effort \($0)"] } ?? [])
        case .fastMode(let isOn):
            return ["/fast \(isOn ? "on" : "off")"]
        }
    }

    func renameThread(_ thread: AgentThread, to title: String) async throws {
        try await history.renameThread(thread.sessionID, to: title, directory: thread.directory)
        onEvent?(.threadInvalidated(sessionID: thread.sessionID))
    }

    func deleteThread(_ thread: AgentThread) async throws {
        try await stopThread(thread)
        // `claude agents --all` keeps listing stopped jobs, which would bring the thread back.
        for session in try await Self.backgroundSessions() where session.kind == "background" && session.sessionID == thread.sessionID {
            guard let id = session.id else { continue }
            _ = try await IntegrationProcess.run("claude", arguments: ["rm", id])
        }
        try await history.deleteThread(thread.sessionID, directory: thread.directory)
        backgroundIDs[thread.sessionID] = nil
        backgroundSessions[thread.sessionID] = nil
        settingsOverrides[thread.sessionID] = nil
        onEvent?(.threadDeleted(sessionID: thread.sessionID))
    }

    func createThread(directory: String, settings: TaskStartSettings?) async throws -> AgentThread {
        let session = try await startBackgroundSession(directory: directory, settings: settings)
        guard var thread = session.thread else {
            throw IntegrationError(message: "Claude did not provide a session identifier.")
        }
        thread.title = "New Claude thread"
        thread.status = .idle
        if let model = settings?.model {
            let change = AgentSettingsChange.model(model, reasoningEffort: settings?.reasoningEffort)
            var override = ClaudeSettingsOverride(reportedBy: thread)
            override.append(change)
            settingsOverrides[thread.sessionID] = override
            thread = change.applying(to: thread)
        }
        return thread
    }

    func forkThread(_ thread: AgentThread) async throws -> AgentThread {
        guard UUID(uuidString: thread.sessionID) != nil else {
            throw IntegrationError(message: "Invalid Claude session identifier.")
        }
        let session = try await startBackgroundSession(directory: thread.directory, resuming: thread.sessionID, forking: true)
        guard let fork = session.thread else {
            throw IntegrationError(message: "Claude did not provide a forked session identifier.")
        }
        return fork
    }

    func prepareLaunch(for thread: AgentThread, intent: AgentLaunchIntent) async throws -> AgentLaunch {
        guard UUID(uuidString: thread.sessionID) != nil else {
            throw IntegrationError(message: "Invalid Claude session identifier.")
        }
        try await openConversation(thread)
        guard let id = backgroundIDs[thread.sessionID] else { throw IntegrationError(message: "Claude is not connected.") }
        return AgentLaunch(executable: "claude", arguments: ["attach", id])
    }

    func stopThread(_ thread: AgentThread) async throws {
        closeSubscription(thread.sessionID)
        resolveDecisions(sessionID: thread.sessionID)
        live[thread.sessionID] = nil
        unsavedTurns[thread.sessionID] = nil
        outgoing[thread.sessionID] = nil
        liveStatuses[thread.sessionID] = nil
        let sessions = try await listBackgroundSessions()
        guard let session = sessions.first(where: { $0.kind == "background" && $0.sessionID == thread.sessionID }),
              let id = session.id else { return }
        _ = try await IntegrationProcess.run("claude", arguments: ["stop", id])
        if let pid = session.pid { try await AgentProcessExit.wait(for: pid) }
        try await refreshBackgroundSessions()
    }

    func didExit(_ thread: AgentThread) {
        requestStatusRefresh()
    }

    func setEnabled(_ isEnabled: Bool) {
        self.isEnabled = isEnabled
        if !isEnabled {
            historyWatcher?.stop()
            historyWatcher = nil
            for id in Array(subscriptions.keys) { closeSubscription(id) }
            for id in Array(subscriptionTasks.keys) { closeSubscription(id) }
            for id in Set(decisions.values.map(\.sessionID)) { resolveDecisions(sessionID: id) }
            hooks.stop()
            live.removeAll()
            unsavedTurns.removeAll()
            outgoing.removeAll()
            liveStatuses.removeAll()
            backgroundListTask?.cancel()
            statusRevision += 1
        }
    }

    private func startBackgroundSession(directory: String, resuming sessionID: String? = nil, forking: Bool = false, settings startSettings: TaskStartSettings? = nil) async throws -> ClaudeBackgroundSession {
        try watchHistory()
        try await ClaudeWorkspaceTrust.accept(directory: directory)
        let settings = try await hooks.start()
        let existingBackground: Bool
        if let sessionID, !forking {
            existingBackground = try await listBackgroundSessions().contains { $0.kind == "background" && $0.sessionID == sessionID }
        } else { existingBackground = false }
        // Any new options on a saved background job tell Claude to COPY it,
        // even if those options equal its old ones. Preserve the job's options.
        var arguments = existingBackground ? ["--bg"] : ["--bg", "--settings", settings.path]
        if let model = startSettings?.model { arguments += ["--model", model] }
        if let effort = startSettings?.reasoningEffort { arguments += ["--effort", effort] }
        if let sessionID { arguments += ["--resume", sessionID] }
        if forking { arguments.append("--fork-session") }
        let output = try await IntegrationProcess.run("claude", arguments: arguments, directory: directory, timeout: .seconds(120))
        guard let line = String(decoding: output, as: UTF8.self).split(separator: "\n").first(where: { $0.hasPrefix("backgrounded") }),
              let field = line.split(separator: "·").dropFirst().first,
              let identifier = field.split(whereSeparator: \.isWhitespace).first else {
            throw IntegrationError(message: "Claude did not return a background session identifier.")
        }
        let id = String(identifier)
        do {
            let session = try await runningSession(jobID: id)
            guard let thread = session.thread else {
                throw IntegrationError(message: "Claude did not provide its background conversation identifier.")
            }
            if forking, thread.sessionID == sessionID {
                throw IntegrationError(message: "Claude did not create an independent forked session.")
            }
            guard forking || sessionID == nil || thread.sessionID == sessionID else {
                throw IntegrationError(message: "This Claude conversation is already open elsewhere. Close that session before opening it here.")
            }
            backgroundIDs[thread.sessionID] = id
            backgroundSessions[thread.sessionID] = session
            return session
        } catch {
            _ = try? await Task {
                try await IntegrationProcess.run("claude", arguments: ["stop", id], directory: directory)
            }.value
            throw error
        }
    }

    /// Waits for a job `claude --bg` just started to be running with a session,
    /// checking again whenever Claude writes the job's state or its worker roster.
    private func runningSession(jobID: String) async throws -> ClaudeBackgroundSession {
        let (changes, continuation) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(1))
        let job = "/jobs/\(jobID)/"
        let watcher = FileSystemWatcher(urls: [configDirectory.appending(path: "jobs"), configDirectory.appending(path: "daemon")],
                                        latency: 0.1, ignoredSubstrings: []) { paths in
            if paths.contains(where: { $0.contains(job) || $0.hasSuffix("/roster.json") }) { continuation.yield() }
        }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(30))
            continuation.finish()
        }
        defer {
            watcher.stop()
            deadline.cancel()
            continuation.finish()
        }
        // The job may already be running before the first change arrives.
        continuation.yield()
        for await _ in changes {
            // A fresh listing, as one already in flight may predate the change.
            if let session = try await Self.backgroundSessions().first(where: {
                $0.kind == "background" && $0.id == jobID && $0.pid != nil && $0.status != nil
                    && $0.state != "stopped" && $0.state != "failed"
            }) { return session }
        }
        try Task.checkCancellation()
        throw IntegrationError(message: "Claude did not provide its background conversation identifier.")
    }

    nonisolated private static func backgroundSessions() async throws -> [ClaudeBackgroundSession] {
        let data = try await IntegrationProcess.run("claude", arguments: ["agents", "--json", "--all"])
        return try JSONDecoder().decode([ClaudeBackgroundSession].self, from: data)
    }

    private func listBackgroundSessions() async throws -> [ClaudeBackgroundSession] {
        if let backgroundListTask { return try await backgroundListTask.value }
        let task = Task { try await Self.backgroundSessions() }
        backgroundListTask = task
        defer { backgroundListTask = nil }
        return try await task.value
    }

    private func refreshBackgroundSessions() async throws {
        statusRevision += 1
        let revision = statusRevision
        let expectedIDs = backgroundIDs
        let sessions = try await listBackgroundSessions()
        try Task.checkCancellation()
        guard revision == statusRevision else { return }
        let presentIDs = Set(sessions.filter { $0.kind == "background" }.compactMap(\.sessionID))
        for (sessionID, id) in expectedIDs where backgroundIDs[sessionID] == id && !presentIDs.contains(sessionID) {
            backgroundSessions[sessionID] = nil
            backgroundIDs[sessionID] = nil
            onEvent?(.threadUpdated(sessionID: sessionID, update: AgentThreadUpdate(status: .unknown)))
        }
        for session in sessions where session.kind == "background" {
            guard let sessionID = session.sessionID, let id = session.id else { continue }
            backgroundIDs[sessionID] = id
            let previous = backgroundSessions.updateValue(session, forKey: sessionID)
            guard previous != session else { continue }
            onEvent?(.threadUpdated(sessionID: sessionID, update: AgentThreadUpdate(status: session.threadStatus)))
            onEvent?(.threadInvalidated(sessionID: sessionID))
        }
    }

    private func requestStatusRefresh() {
        onEvent?(.listInvalidated)
    }

    private func liveTranscript(_ sessionID: String) async throws -> ClaudeLiveTranscript {
        if let existing = live[sessionID] { return existing }
        let loading: Task<[TranscriptMessage], Error>
        if let existing = transcriptLoads[sessionID] { loading = existing }
        else {
            loading = Task { try await savedTranscript(sessionID) }
            transcriptLoads[sessionID] = loading
        }
        defer { transcriptLoads[sessionID] = nil }
        let saved = try await loading.value
        if let existing = live[sessionID] { return existing }
        let transcript = ClaudeLiveTranscript(history: saved)
        live[sessionID] = transcript
        return transcript
    }

    private func subscribe(sessionID: String, jobID: String) {
        guard subscriptions[sessionID] == nil, subscriptionTasks[sessionID] == nil else { return }
        subscriptionTasks[sessionID] = Task { [weak self] in
            guard let self else { return }
            defer { self.subscriptionTasks[sessionID] = nil }
            var attempt = 0
            while !Task.isCancelled, self.isEnabled, self.backgroundIDs[sessionID] == jobID {
                do {
                    let subscription = try await self.daemon.subscribe(jobID: jobID) { [weak self] data in
                        self?.receiveBackground(data, sessionID: sessionID)
                    } onClose: { [weak self] _ in
                        guard let self, self.subscriptions.removeValue(forKey: sessionID) != nil else { return }
                        self.subscriptionTasks[sessionID] = nil
                        self.subscribe(sessionID: sessionID, jobID: jobID)
                    }
                    guard !Task.isCancelled, self.isEnabled else { subscription.close(); return }
                    self.subscriptions[sessionID] = subscription
                    return
                } catch {
                    guard !Task.isCancelled else { return }
                    attempt += 1
                    if attempt == 1 { self.onEvent?(.threadInvalidated(sessionID: sessionID)) }
                    try? await Task.sleep(for: .seconds(min(attempt, 15)))
                }
            }
        }
    }

    private func receiveBackground(_ data: Data, sessionID: String) {
        // The daemon's record can stay "active" after a turn ends, so its snapshot is skipped and
        // chats without our hooks take their status from `claude agents` instead.
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String, type != "stream", type != "snapshot" else { return }
        guard live[sessionID] != nil else { return requestStatusRefresh() }
        let state = event["record"] as? [String: Any] ?? event["patch"] as? [String: Any] ?? [:]
        let status: AgentThreadStatus?
        if type == "settled" {
            status = event["outcome"] as? String == "done" ? .done : .stopped
        } else if state["tempo"] as? String == "blocked" { status = .waiting }
        else if state["state"] as? String == "done" { status = .done }
        else if state["state"] as? String == "failed" { status = .failed }
        else if state["state"] as? String == "stopped" { status = .stopped }
        else if state["tempo"] as? String == "idle" { status = .idle }
        else if state["tempo"] as? String == "active" { status = .processing }
        else { status = nil }
        if let status {
            let status = conversationStatus(status, sessionID: sessionID)
            liveStatuses[sessionID] = status
            onEvent?(.threadUpdated(sessionID: sessionID, update: AgentThreadUpdate(status: status)))
        }
    }

    private func closeSubscription(_ sessionID: String) {
        subscriptionTasks.removeValue(forKey: sessionID)?.cancel()
        let connection = subscriptions.removeValue(forKey: sessionID)
        connection?.onClose = nil
        connection?.close()
    }

    private func receiveHook(_ body: Data) async throws -> Data {
        guard let event = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let sessionID = event["session_id"] as? String, UUID(uuidString: sessionID) != nil,
              let name = event["hook_event_name"] as? String else { return Data("{}".utf8) }
        // Subagent messages must not be mistaken for the main conversation's text or questions.
        if event["agent_id"] as? String != nil, name != "SubagentStart", name != "SubagentStop" { return Data("{}".utf8) }
        let transcript = try await liveTranscript(sessionID)
        // Once the chat moves past an ended turn, that turn's history no longer has all of it.
        if ["UserPromptSubmit", "MessageDisplay", "PreToolUse"].contains(name) { unsavedTurns[sessionID] = nil }
        switch name {
        case "UserPromptSubmit":
            liveStatuses[sessionID] = .processing
            let text = event["prompt"] as? String ?? ""
            var pending: ClaudeOutgoingPrompt?
            if let index = outgoing[sessionID]?.firstIndex(where: { $0.wireText == text }) {
                pending = outgoing[sessionID]?.remove(at: index)
            }
            transcript.prompt(pending?.displayText ?? text, id: event["prompt_id"] as? String ?? UUID().uuidString, images: pending?.images ?? [])
            onEvent?(.threadUpdated(sessionID: sessionID, update: AgentThreadUpdate(status: .processing, updatedAt: .now, startsNewTurn: true)))
        case "MessageDisplay": transcript.display(event)
        case "PreToolUse":
            transcript.tool(event)
            if event["tool_name"] as? String == "AskUserQuestion" {
                onEvent?(.transcriptChanged(sessionID: sessionID))
                return try await requestDecision(event, sessionID: sessionID, eventName: name)
            }
        case "PermissionRequest":
            return try await requestDecision(event, sessionID: sessionID, eventName: name)
        case "Stop":
            liveStatuses[sessionID] = .done
            transcript.finish(event["last_assistant_message"] as? String ?? "")
            // This turn's Stop record is saved only after this hook returns, so the latest one saved now is older.
            unsavedTurns[sessionID] = UnsavedTurn(previousStop: try? await history.transcriptWithStop(sessionID)?.stop)
            resolveDecisions(sessionID: sessionID)
            onEvent?(.threadUpdated(sessionID: sessionID, update: AgentThreadUpdate(status: .done)))
            onEvent?(.threadInvalidated(sessionID: sessionID))
        case "StopFailure":
            liveStatuses[sessionID] = .failed
            transcript.finish(event["last_assistant_message"] as? String ?? event["error_details"] as? String ?? "Claude could not complete this response.")
            resolveDecisions(sessionID: sessionID)
            onEvent?(.threadUpdated(sessionID: sessionID, update: AgentThreadUpdate(status: .failed)))
        default: break
        }
        if name == "UserPromptSubmit" { onEvent?(.threadInvalidated(sessionID: sessionID)) }
        onEvent?(.transcriptChanged(sessionID: sessionID))
        return Data("{}".utf8)
    }

    private func requestDecision(_ event: [String: Any], sessionID: String, eventName: String) async throws -> Data {
        let input = event["tool_input"] as? [String: Any] ?? [:]
        let tool = event["tool_name"] as? String ?? "Tool"
        let questions = (input["questions"] as? [[String: Any]] ?? []).compactMap { value -> AgentQuestion? in
            guard let question = value["question"] as? String else { return nil }
            return AgentQuestion(id: question, title: question,
                                 options: (value["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String },
                                 allowsMultiple: value["multiSelect"] as? Bool ?? false,
                                 optionDescriptions: Dictionary((value["options"] as? [[String: Any]] ?? []).compactMap { option in
                                     guard let label = option["label"] as? String else { return nil }
                                     return (label, option["description"] as? String ?? "")
                                 }, uniquingKeysWith: { _, new in new }))
        }
        let id = "claude:" + UUID().uuidString
        let encoded = try JSONSerialization.data(withJSONObject: input, options: [.prettyPrinted, .sortedKeys])
        let canReview = encoded.count <= 65_536
        let detail = questions.isEmpty
            ? (canReview ? String(decoding: encoded, as: UTF8.self) : "Review this large request in the terminal.")
            : ""
        let request = AgentInteraction(id: id, taskID: "claude:" + sessionID,
                                       title: questions.isEmpty ? "Allow \(tool)?" : "Claude needs your input",
                                       detail: detail, questions: questions, supportsResponse: canReview)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                decisions[id] = ClaudePendingDecision(sessionID: sessionID, eventName: eventName, input: encoded, continuation: continuation)
                liveStatuses[sessionID] = .waiting
                onEvent?(.interactionRequested(request))
                onEvent?(.threadUpdated(sessionID: sessionID, update: AgentThreadUpdate(status: .waiting)))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.decisions.removeValue(forKey: id)?.continuation.resume(throwing: CancellationError())
                self?.onEvent?(.interactionResolved(id: id))
            }
        }
    }

    func respond(to interactionID: String, with decision: AgentDecision) async throws {
        guard let pending = decisions.removeValue(forKey: interactionID) else {
            throw IntegrationError(message: "Claude is no longer waiting for this answer.")
        }
        var output: [String: Any] = ["hookEventName": pending.eventName]
        if pending.eventName == "PreToolUse" {
            output["permissionDecision"] = decision.allowed ? "allow" : "deny"
            if decision.allowed {
                var input = (try? JSONSerialization.jsonObject(with: pending.input)) as? [String: Any] ?? [:]
                input["answers"] = decision.answers.mapValues { $0.joined(separator: ", ") }
                output["updatedInput"] = input
            } else { output["permissionDecisionReason"] = "The user declined to answer." }
        } else {
            output["decision"] = ["behavior": decision.allowed ? "allow" : "deny", "message": "Decision from Atrium"]
        }
        let result = try JSONSerialization.data(withJSONObject: ["hookSpecificOutput": output])
        pending.continuation.resume(returning: result)
        liveStatuses[pending.sessionID] = .processing
        onEvent?(.interactionResolved(id: interactionID))
        onEvent?(.threadUpdated(sessionID: pending.sessionID, update: AgentThreadUpdate(status: .processing)))
    }

    private func resolveDecisions(sessionID: String) {
        for (id, decision) in decisions.filter({ $0.value.sessionID == sessionID }) {
            decisions[id] = nil
            decision.continuation.resume(returning: Data("{}".utf8))
            onEvent?(.interactionResolved(id: id))
        }
    }

    /// Whether a job was launched with Atrium's hooks, which carry its chat and
    /// questions here. Claude keeps a job's launch options to restart it with.
    private func hasHooks(jobID: String) async throws -> Bool {
        let settings = try await hooks.start().path
        let options = try daemon.launchOptions(jobID: jobID)
        return zip(options, options.dropFirst()).contains { $0 == "--settings" && $1 == settings }
    }

    /// Starting a worker is not starting a conversation turn.
    private func conversationStatus(_ status: AgentThreadStatus, sessionID: String) -> AgentThreadStatus {
        if status == .processing, live[sessionID]?.messages.isEmpty == true,
           outgoing[sessionID]?.isEmpty != false { return .idle }
        return status
    }

    private func withStatus(_ source: AgentThread) -> AgentThread {
        var thread = source
        let session = backgroundSessions[thread.sessionID]
        thread.status = conversationStatus(liveStatuses[source.sessionID] ?? session?.threadStatus ?? .unknown, sessionID: source.sessionID)
        // Background metadata supplies the worker’s current project directory.
        if let directory = session?.cwd, !directory.isEmpty {
            if thread.directory.isEmpty { thread.directory = directory }
            if thread.projectDirectory == nil { thread.projectDirectory = directory }
        }
        if let override = settingsOverrides[thread.sessionID] {
            if let applied = override.applied(to: thread) { thread = applied }
            else { settingsOverrides[thread.sessionID] = nil }
        }
        return thread
    }

}

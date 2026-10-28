import Foundation

@MainActor
final class ClaudeAgentAdapter: AgentProviderAdapter {
    let provider = AgentProvider.claude
    let capabilities: AgentCapabilities = [.forkThread, .deleteThread, .renameThread, .prompt, .selectModel]
    var onEvent: ((AgentEvent) -> Void)?
    private let history: ClaudeSessionHistory
    private let store: ClaudeConversationStore
    private let configDirectory: URL
    /// Claude's global config, where it caches account state such as whether fast mode is allowed.
    private let globalConfigFile: URL
    private let defaults: UserDefaults
    private var backgroundIDs: [String: String]
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
    private var outgoing: [String: [ClaudeOutgoingPrompt]] = [:]
    private var liveStatuses: [String: AgentThreadStatus] = [:]
    /// Settings typed into each thread's terminal that its transcript doesn't show yet.
    private var settingsOverrides: [String: ClaudeSettingsOverride] = [:]

    init(defaults: UserDefaults = .standard, configDirectory: URL? = nil) {
        self.defaults = defaults
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
        store = ClaudeConversationStore()
        backgroundIDs = defaults.dictionary(forKey: "integration.claude.backgroundIDs") as? [String: String] ?? [:]
        hooks.onEvent = { [weak self] body in
            guard let self, self.isEnabled else { return Data("{}".utf8) }
            return try await self.receiveHook(body)
        }
    }

    func listThreads() async throws -> [AgentThread] {
        try await refreshBackgroundSessions()
        let saved = try await history.listThreads()
        var threads = Dictionary(saved.map { ($0.sessionID, $0) }, uniquingKeysWith: { _, new in new })
        for thread in backgroundSessions.values.compactMap(\.thread) where threads[thread.sessionID] == nil {
            threads[thread.sessionID] = thread
        }
        for thread in store.threads { threads[thread.sessionID] = thread }
        return AgentThread.unique(threads.values.map(withStatus))
    }

    func readThread(_ id: String) async throws -> AgentThread? {
        if let thread = store.thread(id) { return withStatus(thread) }
        return try await (history.readThread(id) ?? backgroundSessions[id]?.thread).map(withStatus)
    }

    func transcript(for thread: AgentThread) async throws -> [TranscriptMessage] {
        if store.thread(thread.sessionID) != nil { return try await liveTranscript(thread.sessionID).messages }
        return try await history.transcript(thread.sessionID)
    }

    func openConversation(_ thread: AgentThread) async throws {
        guard UUID(uuidString: thread.sessionID) != nil else { throw IntegrationError(message: "Invalid Claude session identifier.") }
        _ = try await hooks.start()
        let sessions = try await listBackgroundSessions()
        let session: ClaudeBackgroundSession
        let wasNative = store.thread(thread.sessionID) != nil
        if let existing = sessions.first(where: {
            $0.kind == "background" && $0.sessionID == thread.sessionID && $0.pid != nil
                && $0.state != "stopped" && $0.state != "failed"
        }) {
            session = existing
        } else {
            let hasSavedBackground = sessions.contains { $0.kind == "background" && $0.sessionID == thread.sessionID }
            session = try await startBackgroundSession(directory: thread.directory, resuming: thread.sessionID)
            if !wasNative && !hasSavedBackground {
                let messages = try await history.transcript(thread.sessionID)
                try store.save(thread)
                try store.saveMessages(messages, for: thread.sessionID)
            }
        }
        guard let id = session.id else { throw IntegrationError(message: "Claude did not provide a background identifier.") }
        backgroundIDs[thread.sessionID] = id
        backgroundSessions[thread.sessionID] = session
        liveStatuses[thread.sessionID] = session.threadStatus
        saveBackgroundIDs()
        if store.thread(thread.sessionID) != nil { _ = try await liveTranscript(thread.sessionID) }
        subscribe(sessionID: thread.sessionID, jobID: id)
    }

    func sendPrompt(_ text: String, images: [URL], to thread: AgentThread) async throws {
        try await openConversation(thread)
        guard store.thread(thread.sessionID) != nil else {
            throw IntegrationError(message: "This background session was started outside Atrium without chat hooks. Open Terminal to continue it.")
        }
        guard let id = backgroundIDs[thread.sessionID] else { throw IntegrationError(message: "Claude is not connected.") }
        let references = images.map { "@\"" + $0.path.replacing("\\", with: "\\\\").replacing("\"", with: "\\\"") + "\"" }
        let prompt = (references + (text.isEmpty ? [] : [text])).joined(separator: "\n")
        let outgoingPrompt = ClaudeOutgoingPrompt(wireText: prompt, displayText: text, images: images.compactMap { TranscriptImage.thumbnail(at: $0) })
        outgoing[thread.sessionID, default: []].append(outgoingPrompt)
        // Never retry an acknowledged write: a failed acknowledgement can still mean
        // Claude queued the prompt. Let the user decide whether to resend.
        do { try await daemon.reply(prompt, jobID: id) }
        catch {
            outgoing[thread.sessionID]?.removeAll { $0.id == outgoingPrompt.id }
            throw error
        }
        onEvent?(.threadUpdated(sessionID: thread.sessionID, update: AgentThreadUpdate(status: .processing, updatedAt: .now)))
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
        if store.thread(thread.sessionID) == nil {
            try await history.renameThread(thread.sessionID, to: title, directory: thread.directory)
            onEvent?(.threadInvalidated(sessionID: thread.sessionID))
            return
        }
        var renamed = thread
        renamed.title = title
        renamed.hasProviderTitle = true
        try store.save(renamed)
        onEvent?(.threadInvalidated(sessionID: thread.sessionID))
    }

    func deleteThread(_ thread: AgentThread) async throws {
        try await stopThread(thread)
        try await history.deleteThread(thread.sessionID, directory: thread.directory)
        try store.delete(thread.sessionID)
        backgroundIDs[thread.sessionID] = nil
        backgroundSessions[thread.sessionID] = nil
        settingsOverrides[thread.sessionID] = nil
        saveBackgroundIDs()
        onEvent?(.threadDeleted(sessionID: thread.sessionID))
    }

    func createThread(directory: String) async throws -> AgentThread {
        let session = try await startBackgroundSession(directory: directory)
        guard var thread = session.thread else {
            throw IntegrationError(message: "Claude did not provide a session identifier.")
        }
        thread.title = "New Claude thread"
        thread.status = .idle
        try store.save(thread)
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
        try store.save(fork)
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
        outgoing[thread.sessionID] = nil
        liveStatuses[thread.sessionID] = nil
        let sessions = try await listBackgroundSessions()
        guard let session = sessions.first(where: { $0.kind == "background" && $0.sessionID == thread.sessionID }),
              let id = session.id else { return }
        _ = try await IntegrationProcess.run("claude", arguments: ["stop", id], directory: thread.directory)
        if let pid = session.pid { try await AgentProcessExit.wait(for: pid) }
        try await refreshBackgroundSessions()
    }

    func didExit(_ thread: AgentThread) {
        requestStatusRefresh()
    }

    func setEnabled(_ isEnabled: Bool) {
        self.isEnabled = isEnabled
        if !isEnabled {
            for id in Array(subscriptions.keys) { closeSubscription(id) }
            for id in Array(subscriptionTasks.keys) { closeSubscription(id) }
            for id in Set(decisions.values.map(\.sessionID)) { resolveDecisions(sessionID: id) }
            hooks.stop()
            live.removeAll()
            outgoing.removeAll()
            liveStatuses.removeAll()
            backgroundListTask?.cancel()
            statusRevision += 1
        }
    }

    private func startBackgroundSession(directory: String, resuming sessionID: String? = nil, forking: Bool = false) async throws -> ClaudeBackgroundSession {
        try await ClaudeWorkspaceTrust.accept(directory: directory)
        let settings = try await hooks.start()
        let existingBackground: Bool
        if let sessionID, !forking {
            existingBackground = try await listBackgroundSessions().contains { $0.kind == "background" && $0.sessionID == sessionID }
        } else { existingBackground = false }
        // Any new options on a saved background job tell Claude to COPY it,
        // even if those options equal its old ones. Preserve the job's options.
        var arguments = existingBackground ? ["--bg"] : ["--bg", "--settings", settings.path]
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
            let clock = ContinuousClock()
            let deadline = clock.now + .seconds(30)
            while clock.now < deadline {
                try Task.checkCancellation()
                if let session = try await listBackgroundSessions().first(where: {
                    $0.kind == "background" && $0.id == id && $0.pid != nil && $0.status != nil
                        && $0.state != "stopped" && $0.state != "failed"
                }),
                   let thread = session.thread {
                    if forking, thread.sessionID == sessionID {
                        throw IntegrationError(message: "Claude did not create an independent forked session.")
                    }
                    guard forking || sessionID == nil || thread.sessionID == sessionID else {
                        throw IntegrationError(message: "This Claude conversation is already open elsewhere. Close that session before opening it here.")
                    }
                    backgroundIDs[thread.sessionID] = id
                    backgroundSessions[thread.sessionID] = session
                    saveBackgroundIDs()
                    return session
                }
                try await Task.sleep(for: .milliseconds(200))
            }
            throw IntegrationError(message: "Claude did not provide its background conversation identifier.")
        } catch {
            _ = try? await Task {
                try await IntegrationProcess.run("claude", arguments: ["stop", id], directory: directory)
            }.value
            throw error
        }
    }

    private func listBackgroundSessions() async throws -> [ClaudeBackgroundSession] {
        if let backgroundListTask { return try await backgroundListTask.value }
        let task = Task {
            let data = try await IntegrationProcess.run("claude", arguments: ["agents", "--json", "--all"])
            return try JSONDecoder().decode([ClaudeBackgroundSession].self, from: data)
        }
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
        saveBackgroundIDs()
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
            loading = Task { try await history.transcript(sessionID) }
            transcriptLoads[sessionID] = loading
        }
        defer { transcriptLoads[sessionID] = nil }
        let saved = try await loading.value
        if let existing = live[sessionID] { return existing }
        // Provider history includes work completed while Atrium was closed.
        let messages = saved.isEmpty ? store.messages(sessionID) : saved
        let transcript = ClaudeLiveTranscript(history: messages)
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
        guard let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let state = event["record"] as? [String: Any] ?? event["patch"] as? [String: Any] ?? [:]
        let status: AgentThreadStatus?
        if event["type"] as? String == "settled" {
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
        guard store.thread(sessionID) != nil else { return Data("{}".utf8) }
        let transcript = try await liveTranscript(sessionID)
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
        case "PostToolUse", "PostToolUseFailure": transcript.tool(event)
        case "Stop":
            liveStatuses[sessionID] = .done
            transcript.finish(event["last_assistant_message"] as? String ?? "")
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
        try store.saveMessages(transcript.messages, for: sessionID)
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

    private func saveBackgroundIDs() {
        defaults.set(backgroundIDs, forKey: "integration.claude.backgroundIDs")
    }

    /// Starting a worker is not starting a conversation turn.
    private func conversationStatus(_ status: AgentThreadStatus, sessionID: String) -> AgentThreadStatus {
        if status == .processing, store.thread(sessionID) != nil,
           store.messages(sessionID).isEmpty, live[sessionID]?.messages.isEmpty != false,
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

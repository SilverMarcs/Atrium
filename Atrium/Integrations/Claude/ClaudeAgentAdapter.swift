import Foundation

@MainActor
final class ClaudeAgentAdapter: AgentProviderAdapter {
    let provider = AgentProvider.claude
    let capabilities: AgentCapabilities = [.forkThread, .deleteThread, .renameThread, .terminalPrompt, .selectModel]
    var onEvent: ((AgentEvent) -> Void)?
    private let history: ClaudeSessionHistory
    private let configDirectory: URL
    /// Claude's global config, where it caches account state such as whether fast mode is allowed.
    private let globalConfigFile: URL
    private let defaults: UserDefaults
    private var backgroundIDs: [String: String]
    private var backgroundSessions: [String: ClaudeBackgroundSession] = [:]
    private var watchers: [FileSystemWatcher] = []
    private var statusTask: Task<Void, Never>?
    private var statusRefreshRequested = false
    private var statusRevision = 0
    private var backgroundListTask: Task<[ClaudeBackgroundSession], Error>?
    private var historyTask: Task<Void, Never>?
    private var needsStatusRefresh = true
    /// Settings typed into each thread's terminal that its transcript doesn't show yet.
    private var settingsOverrides: [String: ClaudeSettingsOverride] = [:]

    init(defaults: UserDefaults = .standard, configDirectory: URL? = nil) {
        self.defaults = defaults
        let configured = IntegrationProcess.environment["CLAUDE_CONFIG_DIR"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let directory = configDirectory ?? configured
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude")
        self.configDirectory = directory.standardizedFileURL.resolvingSymlinksInPath()
        // The global config sits beside the default config directory, or inside a custom one.
        globalConfigFile = (configDirectory ?? configured)?.appending(path: ".claude.json")
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude.json")
        history = ClaudeSessionHistory(configDirectory: self.configDirectory)
        backgroundIDs = defaults.dictionary(forKey: "integration.claude.backgroundIDs") as? [String: String] ?? [:]
    }

    func listThreads() async throws -> [AgentThread] {
        try startWatching()
        if needsStatusRefresh { try await refreshBackgroundSessions() }
        let history = try await history.listThreads().map(withStatus)
        let listedIDs = Set(history.map(\.sessionID))
        let drafts = backgroundSessions.values.compactMap(\.thread).filter { !listedIDs.contains($0.sessionID) }
        return AgentThread.unique(history + drafts)
    }

    func readThread(_ id: String) async throws -> AgentThread? {
        try await history.readThread(id).map(withStatus) ?? backgroundSessions[id]?.thread
    }

    func transcript(for thread: AgentThread) async throws -> [TranscriptMessage] {
        try await history.transcript(thread.sessionID)
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
        try await history.renameThread(thread.sessionID, to: title, directory: thread.directory)
    }

    func deleteThread(_ thread: AgentThread) async throws {
        try await stopThread(thread)
        try await history.deleteThread(thread.sessionID, directory: thread.directory)
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
        try startWatching()
        let sessions = try await listBackgroundSessions()
        let session: ClaudeBackgroundSession
        if let existing = sessions.first(where: { $0.kind == "background" && $0.sessionID == thread.sessionID }) {
            session = existing
        } else {
            session = try await startBackgroundSession(directory: thread.directory, resuming: thread.sessionID)
        }
        guard let id = session.id else { throw IntegrationError(message: "Claude did not provide a background session identifier.") }
        backgroundIDs[thread.sessionID] = id
        if backgroundSessions[thread.sessionID]?.id != id { backgroundSessions[thread.sessionID] = session }
        saveBackgroundIDs()
        return AgentLaunch(executable: "claude", arguments: ["attach", id])
    }

    func stopThread(_ thread: AgentThread) async throws {
        let sessions = try await listBackgroundSessions()
        guard let session = sessions.first(where: { $0.kind == "background" && $0.sessionID == thread.sessionID }),
              let id = session.id else { return }
        _ = try await IntegrationProcess.run("claude", arguments: ["stop", id], directory: thread.directory)
        try await refreshBackgroundSessions()
    }

    func didExit(_ thread: AgentThread) {
        requestStatusRefresh()
    }

    func setEnabled(_ isEnabled: Bool) {
        if !isEnabled {
            watchers.forEach { $0.stop() }
            watchers.removeAll()
            statusTask?.cancel()
            historyTask?.cancel()
            backgroundListTask?.cancel()
            statusRevision += 1
            needsStatusRefresh = true
        }
    }

    private func startBackgroundSession(directory: String, resuming sessionID: String? = nil, forking: Bool = false) async throws -> ClaudeBackgroundSession {
        try await ClaudeWorkspaceTrust.accept(directory: directory)
        let settings = #"{"env":{"CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF":"1"}}"#
        var arguments = ["--bg", "--settings", settings]
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
                if let session = try await listBackgroundSessions().first(where: { $0.kind == "background" && $0.id == id }),
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
                    try startWatching()
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
        needsStatusRefresh = false
        let presentIDs = Set(sessions.filter { $0.kind == "background" }.compactMap(\.sessionID))
        for (sessionID, id) in expectedIDs where backgroundIDs[sessionID] == id && !presentIDs.contains(sessionID) {
            backgroundSessions[sessionID] = nil
            backgroundIDs[sessionID] = nil
            onEvent?(.threadUpdated(sessionID: sessionID, update: AgentThreadUpdate(status: .unknown)))
        }
        saveBackgroundIDs()
        for session in sessions where session.kind == "background" {
            guard let sessionID = session.sessionID, let id = session.id, backgroundIDs[sessionID] == id else { continue }
            let previous = backgroundSessions.updateValue(session, forKey: sessionID)
            guard previous != session else { continue }
            onEvent?(.threadUpdated(sessionID: sessionID, update: AgentThreadUpdate(status: session.threadStatus)))
            onEvent?(.threadInvalidated(sessionID: sessionID))
        }
    }

    private func startWatching() throws {
        guard watchers.isEmpty else { return }
        let directories = ["jobs", "sessions", "projects"].map { configDirectory.appending(path: $0) }
        for directory in directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        watchers = directories.map { directory in
            FileSystemWatcher(url: directory, latency: 0.3, ignoredSubstrings: [], onPathsChanged: { [weak self] paths in
                Task { @MainActor [weak self] in self?.filesChanged(paths) }
            })
        }
    }

    private func filesChanged(_ paths: [String]) {
        guard !watchers.isEmpty else { return }
        let prefix = configDirectory.path + "/"
        var historyChanged = false
        for changedPath in paths {
            // Resolve the parent so aliases also match when the changed file was deleted.
            let changedURL = URL(fileURLWithPath: changedPath).standardizedFileURL
            let url = changedURL.deletingLastPathComponent().resolvingSymlinksInPath()
                .appending(path: changedURL.lastPathComponent)
            let path = url.path
            guard path.hasPrefix(prefix) else { continue }
            let components = path.dropFirst(prefix.count).split(separator: "/")
            guard let area = components.first else { continue }
            if area == "jobs", (components.count == 3 && components.last == "state.json")
                || (components.count == 2 && url.pathExtension.isEmpty) {
                requestStatusRefresh()
            } else if area == "sessions", components.count == 2,
                      url.pathExtension == "json",
                      Int(url.deletingPathExtension().lastPathComponent) != nil {
                // Ignore messaging keys and the periodic fleet-view heartbeat.
                requestStatusRefresh()
            } else if area == "projects" {
                let sessionID: String?
                if components.count == 3, url.pathExtension == "jsonl" {
                    sessionID = url.deletingPathExtension().lastPathComponent
                } else if components.count == 4, components.last == "custom-title.json" {
                    sessionID = String(components[2])
                } else {
                    sessionID = nil
                }
                if let sessionID, UUID(uuidString: sessionID) != nil {
                    if FileManager.default.fileExists(atPath: path) {
                        onEvent?(.threadInvalidated(sessionID: sessionID))
                        if url.pathExtension == "jsonl" { onEvent?(.transcriptChanged(sessionID: sessionID)) }
                    } else {
                        historyChanged = true
                    }
                } else if components.count <= 2 {
                    // Directory removal and coalesced/root events require a new snapshot.
                    historyChanged = true
                }
            }
        }
        if historyChanged { requestHistoryRefresh() }
    }

    private func requestHistoryRefresh() {
        guard historyTask == nil else { return }
        historyTask = Task { [weak self] in
            defer { self?.historyTask = nil }
            do {
                try await Task.sleep(for: .milliseconds(300))
                self?.onEvent?(.listInvalidated)
            } catch {}
        }
    }

    private func requestStatusRefresh() {
        guard !watchers.isEmpty else { return }
        needsStatusRefresh = true
        statusRefreshRequested = true
        guard statusTask == nil else { return }
        statusTask = Task { [weak self] in
            guard let self else { return }
            defer { self.statusTask = nil }
            do {
                try await Task.sleep(for: .milliseconds(300))
                repeat {
                    self.statusRefreshRequested = false
                    try await self.refreshBackgroundSessions()
                    // Stay event-driven while limiting CLI launches during continuous writes.
                    try await Task.sleep(for: .seconds(1))
                } while self.statusRefreshRequested
            } catch is CancellationError {
            } catch {
                self.onEvent?(.listInvalidated)
            }
        }
    }

    private func saveBackgroundIDs() {
        defaults.set(backgroundIDs, forKey: "integration.claude.backgroundIDs")
    }

    private func withStatus(_ source: AgentThread) -> AgentThread {
        var thread = source
        let session = backgroundSessions[thread.sessionID]
        thread.status = session?.threadStatus ?? .unknown
        // Background metadata also covers transcripts whose bounded windows omit cwd.
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

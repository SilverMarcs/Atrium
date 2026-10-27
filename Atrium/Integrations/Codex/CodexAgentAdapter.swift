import Foundation

@MainActor
final class CodexAgentAdapter: AgentProviderAdapter {
    let provider = AgentProvider.codex
    let capabilities: AgentCapabilities = [.forkThread, .markRead, .markUnread, .deleteThread, .deleteDescendants, .renameThread, .prompt, .selectModel]
    var onEvent: ((AgentEvent) -> Void)?
    private let socket = CodexSocket()
    private let defaults: UserDefaults
    // Keep threads archived by older Atrium versions available for restoration.
    private var archivedThreadIDs: Set<String>
    private var connected = false
    private var connectionTask: Task<Void, Error>?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var socketPath: String?
    private var watchers: [FileSystemWatcher] = []
    private var historyTask: Task<Void, Never>?
    /// The turn in progress for each thread, from `turn/started` notifications.
    private var activeTurnIDs: [String: String] = [:]
    /// Each thread's rollout file, where Codex appends every step as it works.
    private var rolloutPaths: [String: String] = [:]
    /// Threads Codex is working on, whose rollout files are followed so the
    /// transcript changes with each step. Item notifications only reach the
    /// thread's own clients, and FSEvents reports the appends only once Codex
    /// closes the file.
    private var workingThreadIDs: Set<String> = []
    private var rolloutWatchers: [String: FileWriteWatcher] = [:]
    /// The configured model and reasoning effort, which threads that never
    /// overrode them leave unset.
    private var defaultModel: String?
    private var defaultReasoningEffort: String?
    private var defaultServiceTier: String?
    /// The service tier that makes each model fast, for models that have one.
    private var fastServiceTiers: [String: String] = [:]
    /// Model settings chosen in Atrium for each thread, sent with the next turn
    /// Atrium starts. Codex has no way to change them between turns.
    private var pendingSettings: [String: [String: String]] = [:]
    /// The service tier chosen in Atrium for each thread. Codex doesn't report
    /// a thread's tier, so threads without one run at the configured default.
    private var serviceTiers: [String: String] = [:]
    /// Turns Atrium started, to tell them apart from turns started on the Mac:
    /// by thread until Codex returns the turn's ID, which it may announce first.
    private var startingTurnThreadIDs: Set<String> = []
    private var startedTurnIDs: Set<String> = []
    /// Prompts waiting for the Mac's terminal to load their thread.
    private var loadWaiters: [String: [CheckedContinuation<Void, Error>]] = [:]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        archivedThreadIDs = Set(defaults.stringArray(forKey: "integration.codex.archivedThreadIDs") ?? [])
        socket.onMessage = { [weak self] in self?.receive($0) }
        socket.onClose = { [weak self] in self?.disconnect(error: $0) }
    }

    private func connect() async throws {
        guard !connected else { return }
        if let connectionTask { return try await connectionTask.value }
        let task = Task { try await establishConnection() }
        connectionTask = task
        defer { connectionTask = nil }
        try await task.value
    }

    private func establishConnection() async throws {
        _ = try await IntegrationProcess.run("codex", arguments: ["app-server", "daemon", "start"])
        let version = try await IntegrationProcess.run("codex", arguments: ["app-server", "daemon", "version"])
        guard let info = try JSONSerialization.jsonObject(with: version) as? [String: Any],
              let path = info["socketPath"] as? String else {
            throw IntegrationError(message: "Codex did not provide its app-server socket. Update the Codex CLI and try again.")
        }
        try await socket.connect(path: path)
        socketPath = path
        do {
            _ = try await request("initialize", params: ["clientInfo": ["name": "atrium", "title": "Atrium", "version": "1.0"], "capabilities": ["experimentalApi": true]])
            socket.send(try JSONSerialization.data(withJSONObject: ["method": "initialized"]))
            connected = true
            await readDefaults()
        } catch {
            disconnect(error: error)
            throw error
        }
    }

    func listThreads() async throws -> [AgentThread] {
        try await connect()
        try startWatching()
        let active = try await listThreads(archived: false)
        guard !archivedThreadIDs.isEmpty else { return active }
        let archived = try await listThreads(archived: true).filter { archivedThreadIDs.contains($0.sessionID) }
        return AgentThread.unique(active + archived)
    }

    private func listThreads(archived: Bool) async throws -> [AgentThread] {
        let data = try await request("thread/list", params: [
            "limit": 25, "sortKey": "recency_at", "sortDirection": "desc",
            "sourceKinds": ["cli", "vscode", "appServer"], "archived": archived
        ])
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = result["data"] as? [[String: Any]] else {
            throw IntegrationError(message: "Codex returned an invalid thread list.")
        }
        let readStates = result["readStates"] as? [String: [String: Any]] ?? [:]
        let threads: [AgentThread] = rows.compactMap { row in
            guard var thread = withDefaults(Self.thread(row)) else { return nil }
            thread.readState = Self.readState(readStates[thread.sessionID])
            rolloutPaths[thread.sessionID] = row["path"] as? String
            return thread
        }
        for thread in threads { followRollout(of: thread.sessionID, status: thread.status) }
        return AgentThread.unique(threads)
    }

    func readThread(_ id: String) async throws -> AgentThread? {
        try await connect()
        let data = try await request("thread/read", params: ["threadId": id, "includeTurns": false])
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let row = result["thread"] as? [String: Any], var thread = withDefaults(Self.thread(row)) else {
            throw IntegrationError(message: "Codex returned an invalid thread.")
        }
        thread.readState = Self.readState(result["readState"] as? [String: Any])
        rolloutPaths[id] = row["path"] as? String ?? rolloutPaths[id]
        return thread
    }

    func markRead(_ thread: AgentThread) async throws -> AgentReadState {
        try await updateReadState(thread, operation: "read")
    }

    func markUnread(_ thread: AgentThread) async throws -> AgentReadState {
        try await updateReadState(thread, operation: "unread")
    }

    private func updateReadState(_ thread: AgentThread, operation: String) async throws -> AgentReadState {
        guard let revision = thread.readState?.revision else {
            throw IntegrationError(message: "This thread does not have a read state yet.")
        }
        try await connect()
        let data = try await request("thread/readState/update", params: [
            "threadId": thread.sessionID, "expectedRevision": revision, "operation": ["type": operation]
        ])
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let state = Self.readState(result["readState"] as? [String: Any]) else {
            throw IntegrationError(message: "Codex returned an invalid read state.")
        }
        return state
    }

    func createThread(directory: String) async throws -> AgentThread {
        try await connect()
        let data = try await request("thread/start", params: ["cwd": directory])
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let row = result["thread"] as? [String: Any], let thread = Self.thread(row) else {
            throw IntegrationError(message: "Codex did not return a new thread.")
        }
        // Archiving persists and unloads the empty thread; restore it for CLI resume.
        // Leave its name unset so Codex can generate a title after the first prompt.
        _ = try await request("thread/archive", params: ["threadId": thread.sessionID])
        _ = try await request("thread/unarchive", params: ["threadId": thread.sessionID])
        return thread
    }

    func forkThread(_ thread: AgentThread) async throws -> AgentThread {
        try await connect()
        let data = try await request("thread/fork", params: ["threadId": thread.sessionID, "excludeTurns": true])
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let row = result["thread"] as? [String: Any], let fork = Self.thread(row),
              fork.sessionID != thread.sessionID else {
            throw IntegrationError(message: "Codex did not return a forked thread.")
        }
        return fork
    }

    func renameThread(_ thread: AgentThread, to title: String) async throws {
        try await connect()
        _ = try await request("thread/name/set", params: ["threadId": thread.sessionID, "name": title])
    }

    func transcript(for thread: AgentThread) async throws -> [TranscriptMessage] {
        try await connect()
        return CodexTranscript.messages(fromTurns: try await turns(of: thread.sessionID))
    }

    /// Starts a turn, or steers the one in progress so the prompt joins it as Codex does mid-turn.
    func sendPrompt(_ text: String, images: [URL], to thread: AgentThread) async throws {
        try await connect()
        try await waitUntilLoaded(thread.sessionID)
        var input: [[String: Any]] = images.map { ["type": "localImage", "path": $0.path(percentEncoded: false)] }
        if !text.isEmpty { input.append(["type": "text", "text": text, "text_elements": []]) }
        if let turnID = try await activeTurnID(of: thread.sessionID) {
            // A steered turn keeps its settings; any chosen ones wait for the next turn.
            _ = try await request("turn/steer", params: ["threadId": thread.sessionID, "input": input, "expectedTurnId": turnID])
        } else {
            let settings = pendingSettings[thread.sessionID] ?? [:]
            var params: [String: Any] = ["threadId": thread.sessionID, "input": input]
            params.merge(settings) { $1 }
            startingTurnThreadIDs.insert(thread.sessionID)
            defer { startingTurnThreadIDs.remove(thread.sessionID) }
            let data = try await request("turn/start", params: params)
            let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            if let turnID = (result?["turn"] as? [String: Any])?["id"] as? String { startedTurnIDs.insert(turnID) }
            if pendingSettings[thread.sessionID] == settings { pendingSettings[thread.sessionID] = nil }
        }
    }

    func models() async throws -> [AgentModel] {
        try await connect()
        return try await listModels()
    }

    func changeSettings(_ change: AgentSettingsChange, of thread: AgentThread) async throws {
        var settings = pendingSettings[thread.sessionID] ?? [:]
        switch change {
        case .model(let model, let reasoningEffort):
            settings["model"] = model
            settings["effort"] = reasoningEffort
        case .fastMode(let isOn):
            let model = settings["model"] ?? thread.model
            guard let tier = isOn ? model.flatMap({ fastServiceTiers[$0] }) : "default" else {
                throw IntegrationError(message: "Fast mode isn’t available with this model.")
            }
            settings["serviceTier"] = tier
            serviceTiers[thread.sessionID] = tier
        }
        pendingSettings[thread.sessionID] = settings
    }

    func interrupt(_ thread: AgentThread) async throws {
        try await connect()
        guard let turnID = try await activeTurnID(of: thread.sessionID) else { return }
        _ = try await request("turn/interrupt", params: ["threadId": thread.sessionID, "turnId": turnID])
    }

    /// Reads a loaded thread's turns directly. An unloaded thread is loaded just long
    /// enough to read it, so this connection doesn't become a client of its turns.
    private func turns(of threadID: String) async throws -> [[String: Any]] {
        do {
            let data = try await request("thread/read", params: ["threadId": threadID, "includeTurns": true])
            return Self.turns(in: data)
        } catch let error as IntegrationError where error.message.localizedStandardContains("not supported") {
            let data = try await request("thread/resume", params: ["threadId": threadID])
            _ = try? await request("thread/unsubscribe", params: ["threadId": threadID])
            return Self.turns(in: data)
        }
    }

    /// The Mac attaches a terminal before a remote prompt, so approvals have somewhere to
    /// appear; its resume loads the thread, which Codex announces to every connection.
    /// A thread loaded already is never announced again, so it's looked up once, after
    /// waiting starts so an announcement in between isn't missed.
    private func waitUntilLoaded(_ threadID: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            loadWaiters[threadID, default: []].append(continuation)
            Task {
                do {
                    let data = try await request("thread/loaded/list", params: [:])
                    let loaded = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [String] ?? []
                    if loaded.contains(threadID) { finishWaiting(for: threadID) }
                } catch {
                    finishWaiting(for: threadID, throwing: error)
                }
            }
        }
    }

    private func finishWaiting(for threadID: String, throwing error: Error? = nil) {
        for waiter in loadWaiters.removeValue(forKey: threadID) ?? [] {
            if let error { waiter.resume(throwing: error) } else { waiter.resume() }
        }
    }

    private func activeTurnID(of threadID: String) async throws -> String? {
        if let turnID = activeTurnIDs[threadID] { return turnID }
        let turn = try await turns(of: threadID).last
        return turn?["status"] as? String == "inProgress" ? turn?["id"] as? String : nil
    }

    private static func turns(in data: Data) -> [[String: Any]] {
        let result = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (result?["thread"] as? [String: Any])?["turns"] as? [[String: Any]] ?? []
    }

    func deleteThread(_ thread: AgentThread) async throws {
        try await connect()
        _ = try await request("thread/delete", params: ["threadId": thread.sessionID])
        archivedThreadIDs.remove(thread.sessionID)
        saveArchivedThreadIDs()
        onEvent?(.threadDeleted(sessionID: thread.sessionID))
        onEvent?(.listInvalidated)
    }

    func prepareLaunch(for thread: AgentThread, intent: AgentLaunchIntent) async throws -> AgentLaunch {
        guard UUID(uuidString: thread.sessionID) != nil else {
            throw IntegrationError(message: "Invalid Codex session identifier.")
        }
        try await connect()
        if archivedThreadIDs.contains(thread.sessionID) {
            _ = try await request("thread/unarchive", params: ["threadId": thread.sessionID])
            archivedThreadIDs.remove(thread.sessionID)
            saveArchivedThreadIDs()
        }
        guard let socketPath else {
            throw IntegrationError(message: "Codex is disconnected. Try again.")
        }
        return AgentLaunch(executable: "codex", arguments: ["--remote", "unix://" + socketPath, "resume", thread.sessionID])
    }

    func stopThread(_ thread: AgentThread) async throws {
        // Settling is local to Atrium; the controller closes its terminal session.
    }

    func didExit(_ thread: AgentThread) {
        finishWaiting(for: thread.sessionID, throwing: IntegrationError(message: "Codex closed before it opened the task."))
        onEvent?(.threadInvalidated(sessionID: thread.sessionID))
    }

    private func saveArchivedThreadIDs() {
        defaults.set(archivedThreadIDs.sorted(), forKey: "integration.codex.archivedThreadIDs")
    }

    func setEnabled(_ isEnabled: Bool) {
        guard !isEnabled else { return }
        watchers.forEach { $0.stop() }
        watchers.removeAll()
        rolloutWatchers.values.forEach { $0.stop() }
        rolloutWatchers.removeAll()
        workingThreadIDs.removeAll()
        historyTask?.cancel()
        connectionTask?.cancel()
        disconnect(error: CancellationError())
    }

    private func startWatching() throws {
        guard watchers.isEmpty else { return }
        let configured = IntegrationProcess.environment["CODEX_HOME"]
            .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        let home = configured ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex")
        let directories = ["sessions", "archived_sessions"].map { home.appending(path: $0) }
        for directory in directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        // fs/watch currently watches immediate children; rollouts live in dated subdirectories.
        watchers = directories.map { directory in
            FileSystemWatcher(url: directory, ignoredSubstrings: [], onPathsChanged: { [weak self] paths in
                Task { @MainActor [weak self] in self?.historyChanged(paths) }
            })
        }
    }

    private func historyChanged(_ paths: [String]) {
        guard !watchers.isEmpty else { return }
        var needsListing = false
        for path in paths {
            let url = URL(fileURLWithPath: path)
            if url.pathExtension == "jsonl" {
                let id = String(url.deletingPathExtension().lastPathComponent.suffix(36))
                guard UUID(uuidString: id) != nil else { continue }
                if FileManager.default.fileExists(atPath: path) {
                    // A new thread's rollout file appears once its first turn starts.
                    rolloutPaths[id] = path
                    watchRolloutIfWorking(id)
                    onEvent?(.threadInvalidated(sessionID: id))
                    // Item notifications only reach clients subscribed to the thread, such as
                    // its terminal; the rollout file changes for every turn regardless.
                    onEvent?(.transcriptChanged(sessionID: id))
                } else {
                    needsListing = true
                }
            } else if url.pathExtension.isEmpty {
                // Covers removed directories and coalesced/root notifications.
                needsListing = true
            }
        }
        guard needsListing, historyTask == nil else { return }
        historyTask = Task { [weak self] in
            defer { self?.historyTask = nil }
            do {
                try await Task.sleep(for: .milliseconds(300))
                self?.onEvent?(.listInvalidated)
            } catch {}
        }
    }

    // MARK: - Rollout files

    /// Follows a thread's rollout file while Codex works on it.
    private func followRollout(of id: String, status: AgentThreadStatus) {
        guard !watchers.isEmpty, status == .processing || status == .waiting else {
            workingThreadIDs.remove(id)
            rolloutWatchers.removeValue(forKey: id)?.stop()
            return
        }
        workingThreadIDs.insert(id)
        if rolloutPaths[id] == nil {
            // Not in the last listing; its row names the file.
            Task {
                guard (try? await readThread(id)) != nil else { return }
                watchRolloutIfWorking(id)
            }
        } else {
            watchRolloutIfWorking(id)
        }
    }

    private func watchRolloutIfWorking(_ id: String) {
        guard workingThreadIDs.contains(id), rolloutWatchers[id] == nil, let path = rolloutPaths[id] else { return }
        rolloutWatchers[id] = FileWriteWatcher(path: path) { [weak self] in
            self?.onEvent?(.transcriptChanged(sessionID: id))
        } onRemove: { [weak self] in
            // Archiving moves the file; the next listing names its new place.
            self?.rolloutPaths[id] = nil
            self?.rolloutWatchers.removeValue(forKey: id)?.stop()
        }
    }

    private func request(_ method: String, params: [String: Any]) async throws -> Data {
        nextID += 1
        let id = nextID
        let data = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        let timeout = Task { [weak self] in
            try await Task.sleep(for: .seconds(15))
            self?.disconnect(error: IntegrationError(message: "Codex request timed out."))
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                socket.send(data)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }

    private func receive(_ data: Data) {
        guard let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if message["method"] == nil, let id = message["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
            if let error = message["error"] as? [String: Any] {
                continuation.resume(throwing: IntegrationError(message: error["message"] as? String ?? "Codex request failed."))
            } else if let result = message["result"], let data = try? JSONSerialization.data(withJSONObject: result) {
                continuation.resume(returning: data)
            } else {
                continuation.resume(throwing: IntegrationError(message: "Codex returned an invalid response."))
            }
        } else if let method = message["method"] as? String,
                  let params = message["params"] as? [String: Any] {
            if method == "thread/deleted", let id = params["threadId"] as? String {
                onEvent?(.threadDeleted(sessionID: id))
                onEvent?(.listInvalidated)
                return
            }
            if ["thread/started", "thread/archived", "thread/unarchived"].contains(method) {
                if let id = params["threadId"] as? String {
                    if method == "thread/unarchived" {
                        archivedThreadIDs.remove(id)
                        saveArchivedThreadIDs()
                    }
                }
                onEvent?(.listInvalidated)
                return
            }
            guard let id = params["threadId"] as? String else { return }
            if ["item/started", "item/completed"].contains(method) {
                onEvent?(.transcriptChanged(sessionID: id))
                return
            }
            if method == "turn/started" {
                let turnID = (params["turn"] as? [String: Any])?["id"] as? String
                activeTurnIDs[id] = turnID
                if !startingTurnThreadIDs.contains(id), !startedTurnIDs.contains(turnID ?? "") {
                    // The Mac's terminal started this turn with its own settings.
                    pendingSettings[id] = nil
                    serviceTiers[id] = nil
                }
                onEvent?(.transcriptChanged(sessionID: id))
                onEvent?(.threadUpdated(sessionID: id, update: AgentThreadUpdate(status: .processing, updatedAt: .now, startsNewTurn: true)))
                onEvent?(.threadInvalidated(sessionID: id))
            } else if method == "thread/status/changed" {
                if (params["status"] as? [String: Any])?["type"] as? String != "notLoaded" {
                    finishWaiting(for: id)
                }
                let status = Self.status(params["status"] as? [String: Any])
                followRollout(of: id, status: status)
                onEvent?(.transcriptChanged(sessionID: id))
                onEvent?(.threadUpdated(sessionID: id, update: AgentThreadUpdate(status: status)))
                onEvent?(.threadInvalidated(sessionID: id))
            } else if method == "thread/name/updated" {
                onEvent?(.threadInvalidated(sessionID: id))
            } else if method == "thread/readState/changed", let state = Self.readState(params["readState"] as? [String: Any]) {
                onEvent?(.threadUpdated(sessionID: id, update: AgentThreadUpdate(readState: state)))
            } else if method == "turn/completed" {
                activeTurnIDs[id] = nil
                if let turnID = (params["turn"] as? [String: Any])?["id"] as? String { startedTurnIDs.remove(turnID) }
                onEvent?(.transcriptChanged(sessionID: id))
                let turn = params["turn"] as? [String: Any]
                switch turn?["status"] as? String {
                case "completed": onEvent?(.threadUpdated(sessionID: id, update: AgentThreadUpdate(status: .done)))
                case "failed": onEvent?(.threadUpdated(sessionID: id, update: AgentThreadUpdate(status: .failed)))
                case "interrupted": onEvent?(.threadUpdated(sessionID: id, update: AgentThreadUpdate(status: .stopped)))
                default: break
                }
                onEvent?(.threadInvalidated(sessionID: id))
            }
        }
    }

    private func disconnect(error: Error) {
        let wasConnected = connected
        connected = false
        socketPath = nil
        socket.close()
        let requests = pending.values
        pending.removeAll()
        for continuation in requests { continuation.resume(throwing: error) }
        for threadID in Array(loadWaiters.keys) { finishWaiting(for: threadID, throwing: error) }
        if wasConnected { onEvent?(.listInvalidated) }
    }

    private static func readState(_ value: [String: Any]?) -> AgentReadState? {
        guard let value, let revision = value["revision"] as? String else { return nil }
        return AgentReadState(revision: revision, isUnread: value["firstUnread"] as? [String: Any] != nil)
    }

    private static func status(_ value: [String: Any]?) -> AgentThreadStatus {
        switch value?["type"] as? String {
        case "active":
            let flags = value?["activeFlags"] as? [String] ?? []
            return flags.contains("waitingOnApproval") || flags.contains("waitingOnUserInput") ? .waiting : .processing
        case "idle": return .idle
        case "systemError": return .failed
        default: return .unknown
        }
    }

    private func readDefaults() async {
        guard let data = try? await request("config/read", params: [:]),
              let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = result["config"] as? [String: Any] else { return }
        defaultModel = config["model"] as? String
        defaultReasoningEffort = config["model_reasoning_effort"] as? String
        defaultServiceTier = config["service_tier"] as? String
        // Fast mode is reported from each model's service tiers.
        _ = try? await listModels()
    }

    /// The models Codex's picker offers, noting each one's fast service tier.
    private func listModels() async throws -> [AgentModel] {
        var rows: [[String: Any]] = []
        var cursor: String?
        repeat {
            var params: [String: Any] = ["limit": 100]
            if let cursor { params["cursor"] = cursor }
            let data = try await request("model/list", params: params)
            guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let page = result["data"] as? [[String: Any]] else {
                throw IntegrationError(message: "Codex returned an invalid model list.")
            }
            rows += page
            cursor = result["nextCursor"] as? String
        } while cursor != nil
        var tiers: [String: String] = [:]
        let models: [AgentModel] = rows.compactMap { row in
            guard row["hidden"] as? Bool != true, let id = row["id"] as? String else { return nil }
            let resolvedID = row["model"] as? String ?? id
            let serviceTiers = row["serviceTiers"] as? [[String: Any]] ?? []
            let fastTier = serviceTiers.first {
                ($0["name"] as? String)?.localizedCaseInsensitiveCompare("Fast") == .orderedSame
            }?["id"] as? String
            if let fastTier {
                tiers[id] = fastTier
                tiers[resolvedID] = fastTier
            }
            let efforts = row["supportedReasoningEfforts"] as? [[String: Any]] ?? []
            return AgentModel(
                id: id,
                resolvedID: resolvedID,
                name: row["displayName"] as? String ?? id,
                summary: row["description"] as? String ?? "",
                reasoningEfforts: efforts.compactMap { $0["reasoningEffort"] as? String },
                supportsFastMode: fastTier != nil
            )
        }
        fastServiceTiers = tiers
        return models
    }

    /// Fills in the configured settings a thread didn't override, and shows the
    /// settings chosen in Atrium until its next turn.
    private func withDefaults(_ thread: AgentThread?) -> AgentThread? {
        guard var thread else { return nil }
        let pending = pendingSettings[thread.sessionID] ?? [:]
        thread.model = pending["model"] ?? thread.model ?? defaultModel
        thread.reasoningEffort = pending["effort"] ?? thread.reasoningEffort ?? defaultReasoningEffort
        if let fastTier = thread.model.flatMap({ fastServiceTiers[$0] }) {
            thread.isFastMode = (serviceTiers[thread.sessionID] ?? defaultServiceTier) == fastTier
        }
        return thread
    }

    private static func thread(_ row: [String: Any]) -> AgentThread? {
        guard let id = row["id"] as? String, let directory = row["cwd"] as? String else { return nil }
        let name = (row["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = row["preview"] as? String ?? ""
        let hasProviderTitle = !name.isEmpty && name != "New Codex thread"
        // Match thread/list's main-task sources. Subagents have an object-valued
        // source, and newer servers also report parentThreadId. A fork is still a main task.
        let isMainTask = row["parentThreadId"] as? String == nil
            && ["cli", "vscode", "appServer"].contains(row["source"] as? String ?? "")
        return AgentThread(
            sessionID: id, provider: .codex,
            title: hasProviderTitle ? name : (preview.isEmpty ? "New Codex thread" : String(preview.prefix(160))),
            directory: directory, updatedAt: Date(timeIntervalSince1970: row["recencyAt"] as? Double ?? row["updatedAt"] as? Double ?? 0),
            status: status(row["status"] as? [String: Any]), isMainTask: isMainTask, hasProviderTitle: hasProviderTitle,
            model: row["model"] as? String, reasoningEffort: row["reasoningEffort"] as? String
        )
    }
}

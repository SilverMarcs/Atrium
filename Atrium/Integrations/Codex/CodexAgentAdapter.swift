import Foundation

@MainActor
final class CodexAgentAdapter: AgentProviderAdapter {
    let provider = AgentProvider.codex
    let capabilities: AgentCapabilities = [.forkThread, .markRead, .markUnread, .deleteThread, .deleteDescendants, .renameThread]
    var onEvent: ((AgentEvent) -> Void)?
    private let socket = CodexSocket()
    private let defaults: UserDefaults
    private var archivedThreadIDs: Set<String>
    private var archivingThreadIDs: Set<String> = []
    private var connected = false
    private var connectionTask: Task<Void, Error>?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Data, Error>] = [:]
    private var socketPath: String?
    private var watchers: [FileSystemWatcher] = []
    private var historyTask: Task<Void, Never>?

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
            guard var thread = Self.thread(row) else { return nil }
            thread.readState = Self.readState(readStates[thread.sessionID])
            return thread
        }
        return AgentThread.unique(threads)
    }

    func readThread(_ id: String) async throws -> AgentThread? {
        try await connect()
        let data = try await request("thread/read", params: ["threadId": id, "includeTurns": false])
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let row = result["thread"] as? [String: Any], var thread = Self.thread(row) else {
            throw IntegrationError(message: "Codex returned an invalid thread.")
        }
        thread.readState = Self.readState(result["readState"] as? [String: Any])
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
        guard !archivedThreadIDs.contains(thread.sessionID) else { return }
        try await connect()
        archivingThreadIDs.insert(thread.sessionID)
        defer { archivingThreadIDs.remove(thread.sessionID) }
        do {
            _ = try await request("thread/archive", params: ["threadId": thread.sessionID])
        } catch {
            if !archivedThreadIDs.contains(thread.sessionID) { throw error }
        }
        archivedThreadIDs.insert(thread.sessionID)
        saveArchivedThreadIDs()
        onEvent?(.listInvalidated)
    }

    func didExit(_ thread: AgentThread) {
        onEvent?(.threadInvalidated(sessionID: thread.sessionID))
    }

    private func saveArchivedThreadIDs() {
        defaults.set(archivedThreadIDs.sorted(), forKey: "integration.codex.archivedThreadIDs")
    }

    func setEnabled(_ isEnabled: Bool) {
        guard !isEnabled else { return }
        watchers.forEach { $0.stop() }
        watchers.removeAll()
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
                    onEvent?(.threadInvalidated(sessionID: id))
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
                    if method == "thread/archived", archivingThreadIDs.contains(id) {
                        archivedThreadIDs.insert(id)
                        saveArchivedThreadIDs()
                    } else if method == "thread/unarchived" {
                        archivedThreadIDs.remove(id)
                        saveArchivedThreadIDs()
                    }
                }
                onEvent?(.listInvalidated)
                return
            }
            guard let id = params["threadId"] as? String else { return }
            if method == "turn/started" {
                onEvent?(.threadUpdated(sessionID: id, update: AgentThreadUpdate(status: .processing, updatedAt: .now, startsNewTurn: true)))
                onEvent?(.threadInvalidated(sessionID: id))
            } else if method == "thread/status/changed" {
                onEvent?(.threadUpdated(sessionID: id, update: AgentThreadUpdate(status: Self.status(params["status"] as? [String: Any]))))
                onEvent?(.threadInvalidated(sessionID: id))
            } else if method == "thread/name/updated" {
                onEvent?(.threadInvalidated(sessionID: id))
            } else if method == "thread/readState/changed", let state = Self.readState(params["readState"] as? [String: Any]) {
                onEvent?(.threadUpdated(sessionID: id, update: AgentThreadUpdate(readState: state)))
            } else if method == "turn/completed" {
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

    private static func thread(_ row: [String: Any]) -> AgentThread? {
        guard let id = row["id"] as? String, let directory = row["cwd"] as? String else { return nil }
        let name = (row["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = row["preview"] as? String ?? ""
        let hasProviderTitle = !name.isEmpty && name != "New Codex thread"
        return AgentThread(
            sessionID: id, provider: .codex,
            title: hasProviderTitle ? name : (preview.isEmpty ? "New Codex thread" : String(preview.prefix(160))),
            directory: directory, updatedAt: Date(timeIntervalSince1970: row["recencyAt"] as? Double ?? row["updatedAt"] as? Double ?? 0),
            status: status(row["status"] as? [String: Any]), hasProviderTitle: hasProviderTitle
        )
    }
}

import Foundation
import Network

/// Claude calls directly into Atrium. Persistent endpoint settings let running workers reconnect after relaunch.
@MainActor
final class ClaudeHookServer {
    var onEvent: ((Data) async throws -> Data)?
    private let storage: URL
    private var listener: NWListener?
    private var connections: [UUID: ClaudeHookHTTPConnection] = [:]
    private var startup: Task<URL, Error>?
    private var settingsURL: URL?

    init() {
        #if DEBUG
        let folder = "Atrium/ClaudeBridge-Development"
        #else
        let folder = "Atrium/ClaudeBridge"
        #endif
        self.storage = URL.applicationSupportDirectory.appending(path: folder, directoryHint: .isDirectory)
    }

    func start() async throws -> URL {
        if let settingsURL, listener != nil { return settingsURL }
        if let startup { return try await startup.value }
        let task = Task { try await self.listen() }
        startup = task
        defer { startup = nil }
        return try await task.value
    }

    func stop() {
        startup?.cancel()
        startup = nil
        listener?.cancel()
        listener = nil
        settingsURL = nil
        for connection in Array(connections.values) { connection.close() }
        connections.removeAll()
    }

    func stopAndWait() async {
        guard let listener else { stop(); return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            listener.stateUpdateHandler = { state in
                if case .cancelled = state { continuation.resume() }
            }
            stop()
        }
    }

    private func listen() async throws -> URL {
        try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let endpointFile = storage.appending(path: "endpoint.json")
        let saved = (try? Data(contentsOf: endpointFile)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let token = saved?["token"] as? String ?? UUID().uuidString + UUID().uuidString
        let port = (saved?["port"] as? UInt16).flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in
                guard let self, self.listener === listener else { connection.cancel(); return }
                let id = UUID()
                let client = ClaudeHookHTTPConnection(connection: connection, token: token) { [weak self] body in
                    guard let onEvent = self?.onEvent else { return Data("{}".utf8) }
                    return try await onEvent(body)
                } finished: { [weak self] in self?.connections[id] = nil }
                self.connections[id] = client
                client.start()
            }
        }
        let timeout = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            listener.cancel()
        }
        defer { timeout.cancel() }
        let actualPort: UInt16 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                var pending: CheckedContinuation<UInt16, Error>? = continuation
                listener.stateUpdateHandler = { state in
                    Task { @MainActor in
                        guard let current = pending else { return }
                        switch state {
                        case .ready:
                            guard let port = listener.port?.rawValue else { return }
                            pending = nil
                            current.resume(returning: port)
                        case .failed(let error): pending = nil; current.resume(throwing: error)
                        case .cancelled: pending = nil; current.resume(throwing: CancellationError())
                        default: break
                        }
                    }
                }
                listener.start(queue: .global(qos: .utility))
            }
        } onCancel: { listener.cancel() }
        let endpoint = try JSONSerialization.data(withJSONObject: ["port": actualPort, "token": token])
        try endpoint.write(to: endpointFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: endpointFile.path)
        let events = ["UserPromptSubmit", "MessageDisplay", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PermissionRequest", "Stop", "StopFailure", "SubagentStart", "SubagentStop", "PreCompact", "PostCompact"]
        let hook: [String: Any] = ["type": "http", "url": "http://127.0.0.1:\(actualPort)/claude", "headers": ["Authorization": "Bearer " + token], "timeout": 600]
        let hooks = Dictionary(uniqueKeysWithValues: events.map { ($0, [["hooks": [hook]]]) })
        let settings: [String: Any] = ["hooks": hooks, "env": ["CLAUDE_CODE_DISABLE_BG_EXIT_HANDOFF": "1"]]
        let file = storage.appending(path: "settings.json")
        try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys]).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        settingsURL = file
        return file
    }
}

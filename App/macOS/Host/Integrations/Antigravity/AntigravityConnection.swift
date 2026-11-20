import AppKit
import AtriumProtocol
import Foundation
import OSLog

/// `agy acp`, Antigravity's Agent Client Protocol server, run as Atrium's
/// child: JSON-RPC, one message per line, over its standard input and output.
/// One process serves every session, and it goes when Atrium does, as its
/// input closes.
@MainActor
final class AntigravityConnection {
    /// The agent's notifications, such as `session/update`.
    var onNotification: ((_ method: String, _ params: [String: Any]) -> Void)?
    /// The agent's requests of Atrium, each answered once with `respond`.
    var onRequest: ((_ request: AntigravityRequest) -> Void)?
    /// The process ended, with every request it hadn't answered.
    var onClose: (() -> Void)?
    private(set) var isRunning = false

    private var process: Process?
    private var input: FileHandle?
    private var starting: Task<Void, Error>?
    private var reading: Task<Void, Never>?
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<Reply, Error>] = [:]
    private var log: URL?
    private var languageServerPort: Int?

    /// Replies stay on the main actor, including across continuation delivery.
    @MainActor
    private final class Reply {
        let result: [String: Any]
        init(_ result: [String: Any]) { self.result = result }
    }

    init() {
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
    }

    /// Starts the server and introduces Atrium, unless it's running.
    func start() async throws {
        if isRunning { return }
        if let starting { return try await starting.value }
        let task = Task { try await launch() }
        starting = task
        defer { starting = nil }
        try await task.value
    }

    /// Where the server runs. It reports this folder for sessions that never
    /// said where theirs run, so it's one of Atrium's own, which no chat uses.
    static let folder = HostStorage.directory.appending(path: "Antigravity", directoryHint: .isDirectory)

    private func launch() async throws {
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        // Its log names the port of its language server, and goes with it.
        let log = Self.folder.appending(path: "acp-\(UUID().uuidString).log")
        self.log = log
        languageServerPort = nil
        let process = IntegrationProcess.make("agy", arguments: ["acp", "--log-file", log.filePath], directory: Self.folder.filePath)
        // Agents find the bundled `atrium` first.
        process.environment?["PATH"] = IntegrationProcess.agentPath
        let input = Pipe()
        // A write after the server quits fails rather than raising SIGPIPE.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] process in
            Task { @MainActor [weak self] in self?.ended(process) }
        }
        try process.run()
        self.process = process
        self.input = input.fileHandleForWriting
        isRunning = true
        let lines = output.fileHandleForReading.bytes.lines
        reading = Task.detached { [weak self] in
            do {
                for try await line in lines {
                    let data = Data(line.utf8)
                    await self?.receive(data)
                }
            } catch {}
        }
        do {
            _ = try await request("initialize", [
                "protocolVersion": 1,
                "clientCapabilities": ["elicitation": ["form": [String: Any]()]],
                "clientInfo": ["name": "Atrium", "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"],
            ], timeout: .seconds(30))
        } catch {
            stop()
            throw error
        }
    }

    /// Sends a request and returns its result, or throws the error the agent
    /// answered with. A turn's prompt has no timeout: it lasts the turn.
    @discardableResult
    func request(_ method: String, _ params: [String: Any], timeout: Duration? = .seconds(60)) async throws -> [String: Any] {
        guard let input, isRunning else { throw IntegrationError(message: "Antigravity isn’t running.") }
        nextID += 1
        let id = nextID
        let line = try Self.line(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        let deadline = timeout.map { timeout in
            Task { [weak self] in
                try await Task.sleep(for: timeout)
                self?.finish(id, with: .failure(IntegrationError(message: "Antigravity didn’t answer in time.")))
            }
        }
        defer { deadline?.cancel() }
        let reply: Reply = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pending[id] = continuation
                do {
                    try input.write(contentsOf: line)
                } catch {
                    finish(id, with: .failure(error))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, with: .failure(CancellationError())) }
        }
        return reply.result
    }

    func notify(_ method: String, _ params: [String: Any]) {
        guard let line = try? Self.line(["jsonrpc": "2.0", "method": method, "params": params]) else { return }
        try? input?.write(contentsOf: line)
    }

    /// Answers one of the agent's requests.
    func respond(to request: AntigravityRequest, with result: [String: Any]) {
        reply(to: request, ["result": result])
    }

    /// Answers a request Atrium doesn't take, such as reading a file for the agent.
    func refuse(_ request: AntigravityRequest) {
        reply(to: request, ["error": ["code": -32601, "message": "Atrium doesn’t handle \(request.method)."]])
    }

    private func reply(to request: AntigravityRequest, _ body: [String: Any]) {
        guard let id = try? JSONSerialization.jsonObject(with: request.id, options: .fragmentsAllowed) else { return }
        var message = body
        message["jsonrpc"] = "2.0"
        message["id"] = id
        guard let line = try? Self.line(message) else { return }
        try? input?.write(contentsOf: line)
    }

    /// Ends the server, which drops every session it has open.
    func stop() {
        guard let process else { return }
        try? input?.close()
        if process.isRunning { process.terminate() }
        ended(process)
    }

    private func ended(_ ended: Process) {
        guard process === ended else { return }
        process = nil
        input = nil
        isRunning = false
        reading?.cancel()
        reading = nil
        if let log { try? FileManager.default.removeItem(at: log) }
        log = nil
        languageServerPort = nil
        let waiting = pending
        pending.removeAll()
        for continuation in waiting.values {
            continuation.resume(throwing: IntegrationError(message: "Antigravity stopped. Check that agy is installed and signed in."))
        }
        onClose?()
    }

    private func finish(_ id: Int, with result: Result<[String: Any], Error>) {
        pending.removeValue(forKey: id)?.resume(with: result.map(Reply.init))
    }

    private func receive(_ data: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return }
        let method = message["method"] as? String
        if let method, let id = message["id"] {
            guard let encoded = try? JSONSerialization.data(withJSONObject: id, options: .fragmentsAllowed) else { return }
            onRequest?(AntigravityRequest(id: encoded, method: method, params: message["params"] as? [String: Any] ?? [:]))
        } else if let method {
            onNotification?(method, message["params"] as? [String: Any] ?? [:])
        } else if let id = message["id"] as? Int {
            if let error = message["error"] as? [String: Any] {
                let text = error["message"] as? String ?? "Antigravity refused the request."
                Logger(subsystem: "Atrium", category: "Antigravity").error("Request \(id) failed: \(text, privacy: .public)")
                finish(id, with: .failure(AntigravityError(code: error["code"] as? Int, message: text)))
            } else {
                finish(id, with: .success(message["result"] as? [String: Any] ?? [:]))
            }
        }
    }

    private static func line(_ message: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(10)
        return data
    }

    // MARK: - Language server

    /// Calls the server's own language server, the local API Antigravity's
    /// terminal app uses for what ACP lacks, such as forking, rewinding,
    /// renaming and deleting conversations. It shares the saved conversations
    /// ACP sessions read, and answers protobuf messages as JSON.
    func languageServer(_ method: String, _ body: [String: Any]) async throws -> Data {
        try await start()
        let port: Int
        if let known = languageServerPort {
            port = known
        } else {
            port = try await readLanguageServerPort()
            languageServerPort = port
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)/exa.language_server_pb.LanguageServerService/\(method)") else {
            throw IntegrationError(message: "Antigravity's language server has no address.")
        }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await Self.session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let message = (reply?["message"] as? String).map { $0.replacing(#/\s\(error ID: [0-9a-f]+\)/#, with: "") }
            throw AntigravityError(code: nil, message: message ?? "Antigravity refused \(method).")
        }
        return data
    }

    /// A language server call's reply, read as JSON.
    func languageServerReply(_ method: String, _ body: [String: Any]) async throws -> [String: Any] {
        (try JSONSerialization.jsonObject(with: try await languageServer(method, body)) as? [String: Any]) ?? [:]
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        return URLSession(configuration: configuration)
    }()

    /// The port the server's log says its language server listens on for plain HTTP.
    private func readLanguageServerPort() async throws -> Int {
        for _ in 0..<50 {
            if let log, let text = try? String(contentsOf: log, encoding: .utf8),
               let match = text.firstMatch(of: /listening on random port at (\d+) for HTTP\n/), let port = Int(match.1) {
                return port
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw IntegrationError(message: "Antigravity's language server didn't start. Update agy and try again.")
    }
}

extension AntigravityConnection {
    /// What the server offers a session, its models, modes and the sign-in's
    /// plan, from resuming the newest saved conversation that `open` doesn't
    /// name, which changes nothing in it. Antigravity saves every session it
    /// starts, even one never prompted, so one is started only when there's none.
    func setup(avoiding open: Set<String> = []) async throws -> [String: Any] {
        let saved = try await request("session/list", [:])["sessions"] as? [[String: Any]] ?? []
        for row in saved.prefix(3) {
            guard let id = row["sessionId"] as? String, !open.contains(id), let cwd = row["cwd"] as? String,
                  let reply = try? await request("session/resume", ["sessionId": id, "cwd": cwd, "mcpServers": []]) else { continue }
            _ = try? await request("session/close", ["sessionId": id], timeout: .seconds(10))
            return reply
        }
        let reply = try await request("session/new", ["cwd": Self.folder.filePath, "mcpServers": []])
        if let id = reply["sessionId"] as? String {
            _ = try? await request("session/close", ["sessionId": id], timeout: .seconds(10))
        }
        return reply
    }
}

/// A request the agent made of Atrium, kept until it's answered.
struct AntigravityRequest {
    /// The JSON-RPC ID, as the agent sent it: a string or a number.
    let id: Data
    let method: String
    let params: [String: Any]
}

struct AntigravityError: LocalizedError {
    let code: Int?
    let message: String
    var errorDescription: String? { message }
    /// The session isn't open in the server, which `session/load` fixes.
    var isSessionNotFound: Bool { message.localizedStandardContains("session not found") }
}

import Foundation
import Network

/// Agents call directly into Atrium on the loopback interface: Claude's hooks at
/// `/claude`, with the bridge's own token. ChatGPT reaches Atrium's MCP tools at
/// `/mcp`, with its own credential, through the tunnel client running on this
/// Mac. A persistent endpoint lets running agents reconnect after relaunch.
@MainActor
final class AgentBridgeServer {
    struct Endpoint: Equatable {
        let port: UInt16
        let token: String

        var authorization: String { "Bearer " + token }

        func url(_ path: String) -> String { "http://127.0.0.1:\(port)/\(path)" }
    }

    var onClaudeHook: ((Data) async throws -> Data)?
    /// Answers `/mcp`; set once the host has everything its tools reach.
    var toolServer: AtriumToolServer?
    /// Where agents' launch files that point at the endpoint are kept.
    let storage: URL
    private var listener: NWListener?
    private var connections: [UUID: AgentBridgeConnection] = [:]
    private var startup: Task<Endpoint, Error>?
    private var endpoint: Endpoint?

    init() {
        // Claude identifies jobs started with Atrium's hooks by their settings
        // file, which lives here, so the folder keeps its original name.
        #if DEBUG
        let folder = "ClaudeBridge-Development"
        #else
        let folder = "ClaudeBridge"
        #endif
        self.storage = HostStorage.directory.appending(path: folder, directoryHint: .isDirectory)
    }

    /// Where the bridge listens, for setting up clients outside Atrium such as the tunnel client.
    var currentEndpoint: Endpoint? { listener == nil ? nil : endpoint }

    func start() async throws -> Endpoint {
        if let endpoint, listener != nil { return endpoint }
        if let startup { return try await startup.value }
        let task = Task { try await self.listen() }
        startup = task
        defer { startup = nil }
        return try await task.value
    }

    private func route(_ request: BridgeRequest, token: String) async -> BridgeResponse {
        switch request.path {
        case "/claude":
            guard request.method == "POST" else { return BridgeResponse(status: 405) }
            guard request.headers["authorization"] == "Bearer " + token else { return BridgeResponse(status: 403) }
            guard let onClaudeHook else { return BridgeResponse(status: 200, body: Data("{}".utf8)) }
            do {
                return BridgeResponse(status: 200, body: try await onClaudeHook(request.body))
            } catch {
                // A hook that cannot reach its native UI must leave Claude's terminal fallback usable.
                return BridgeResponse(status: 200, body: Data("{}".utf8))
            }
        case "/mcp":
            guard let toolServer else { return BridgeResponse(status: 503) }
            return await toolServer.respond(to: request)
        default:
            return BridgeResponse(status: 404)
        }
    }

    private func listen() async throws -> Endpoint {
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
                let client = AgentBridgeConnection(connection: connection) { [weak self] request in
                    guard let self else { return BridgeResponse(status: 503) }
                    return await self.route(request, token: token)
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
        let data = try JSONSerialization.data(withJSONObject: ["port": actualPort, "token": token])
        try data.write(to: endpointFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: endpointFile.path)
        let endpoint = Endpoint(port: actualPort, token: token)
        self.endpoint = endpoint
        return endpoint
    }

    /// Writes a launch file only Atrium's user can read, since it holds the endpoint's token.
    func writePrivateFile(_ object: [String: Any], named name: String) throws -> URL {
        let file = storage.appending(path: name)
        try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }
}

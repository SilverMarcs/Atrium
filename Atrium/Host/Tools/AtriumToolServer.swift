import Foundation
import MCP
import OSLog

/// One group of Atrium's tools. Every caller shares the implementation; what
/// each one may see and do is decided per caller.
@MainActor
protocol ToolKit: AnyObject {
    var group: ToolGroup { get }
    var tools: [Tool] { get }
    /// What a caller with this group is told about it when it connects.
    func instructions(for caller: ToolCaller) -> String
    /// Throws `ToolError` for a call the tool turns down.
    func call(_ name: String, arguments: [String: Value], from caller: ToolCaller) async throws -> CallTool.Result
}

nonisolated extension CallTool.Result {
    static func text(_ text: String, isError: Bool = false) -> Self {
        Self(content: [.text(text: text, annotations: nil, _meta: nil)], isError: isError ? true : nil)
    }
}

/// A call a tool turned down, reported to the model as a failed result it can act on.
nonisolated struct ToolError: Error {
    let message: String

    init(_ message: String) {
        self.message = message
    }
}

/// Atrium's MCP server: one implementation for every agent Atrium starts and
/// for ChatGPT, served statelessly over the bridge.
///
/// Each request is authenticated by its bearer token alone, which names the
/// caller, so a model never supplies its own identity. A fresh SDK server
/// answers each request with only the tool groups that caller may use and
/// Settings has turned on, and calls are checked again against the same rule.
@MainActor
final class AtriumToolServer {
    /// The name agents know the server by. Claude prefixes its tools with `mcp__atrium__`.
    nonisolated static let name = "atrium"

    private static let log = Logger(subsystem: "Atrium", category: "Tools")
    private let credentials: ToolCredentials
    private let kits: [any ToolKit]
    private let defaults: UserDefaults

    init(credentials: ToolCredentials, kits: [any ToolKit], defaults: UserDefaults = .standard) {
        self.credentials = credentials
        self.kits = kits
        self.defaults = defaults
    }

    /// Every tool name, for agents whose own permission rules list them.
    var allToolNames: [String] { kits.flatMap { $0.tools.map(\.name) } }

    /// The groups a caller may use right now. Settings turn groups on and off
    /// for sessions; ChatGPT always has the orchestration tools, as turning its
    /// access on is what it's for.
    func groups(for caller: ToolCaller) -> Set<ToolGroup> {
        caller == .remote ? caller.permittedGroups : ToolGroup.enabled(in: defaults).intersection(caller.permittedGroups)
    }

    func respond(to request: BridgeRequest) async -> BridgeResponse {
        // Browsers send an Origin; agents and the tunnel client don't. A page
        // can't read the token, but refuse it outright anyway.
        if let origin = request.headers["origin"], !Self.isLoopback(origin) {
            return BridgeResponse(status: 403)
        }
        guard let caller = credentials.caller(presenting: request.headers["authorization"]) else {
            return BridgeResponse(status: 401, headers: ["WWW-Authenticate": "Bearer"])
        }
        let groups = groups(for: caller)
        let available = kits.filter { groups.contains($0.group) }
        let instructions = available.map { $0.instructions(for: caller) }.joined(separator: "\n\n")
        let server = Server(
            name: Self.name, version: "2.0", title: "Atrium",
            instructions: instructions.isEmpty ? nil : instructions,
            capabilities: .init(tools: .init(listChanged: false))
        )
        let tools = available.flatMap(\.tools)
        await server.withMethodHandler(ListTools.self) { _ in ListTools.Result(tools: tools) }
        let authorization = request.headers["authorization"]
        await server.withMethodHandler(CallTool.self) { [weak self] params in
            guard let self else { return .text("Atrium has stopped.", isError: true) }
            return await self.call(params.name, arguments: params.arguments ?? [:], authorization: authorization)
        }
        let transport = StatelessHTTPServerTransport(validationPipeline: StandardValidationPipeline(validators: [
            AcceptHeaderValidator(mode: .jsonOnly),
            ContentTypeValidator(),
            ProtocolVersionValidator(),
        ]))
        do {
            try await server.start(transport: transport)
        } catch {
            return BridgeResponse(status: 500)
        }
        let response = await transport.handleRequest(HTTPRequest(
            method: request.method, headers: request.headers, body: Self.decodableBody(request.body), path: request.path
        ))
        await server.stop()
        let method = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any])?["method"] as? String ?? request.method
        Self.log.debug("\(String(describing: caller), privacy: .public) \(method, privacy: .public) → \(response.statusCode)")
        return BridgeResponse(status: response.statusCode, headers: response.headers, body: response.bodyData ?? Data())
    }

    private func call(_ name: String, arguments: [String: Value], authorization: String?) async -> CallTool.Result {
        // Who's calling is looked up again, as a session may have been named since.
        guard let caller = credentials.caller(presenting: authorization) else { return .text("Atrium no longer accepts this credential.", isError: true) }
        guard caller != .startingSession else { return .text("Atrium is still starting this session. Try again in a moment.", isError: true) }
        // Settings may have changed since the caller listed its tools.
        let groups = groups(for: caller)
        // Tools a caller may never use don't exist as far as it can tell.
        guard let kit = kits.first(where: { caller.permittedGroups.contains($0.group) && $0.tools.contains { $0.name == name } }) else {
            return .text("Atrium has no tool named \(name).", isError: true)
        }
        guard groups.contains(kit.group) else {
            return .text("\(name) isn't available to you. The user can turn it on in Atrium Settings → Integrations.", isError: true)
        }
        do {
            return try await kit.call(name, arguments: arguments, from: caller)
        } catch let error as ToolError {
            return .text(error.message, isError: true)
        } catch {
            return .text(error.localizedDescription, isError: true)
        }
    }

    /// The SDK reads a client's experimental capabilities as strings only, so
    /// ChatGPT's object-valued ones fail its `initialize` (swift-sdk issue #262).
    /// Atrium uses none of them, so they're dropped before the SDK sees them.
    private static func decodableBody(_ body: Data) -> Data {
        guard var message = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              message["method"] as? String == "initialize",
              var params = message["params"] as? [String: Any],
              var capabilities = params["capabilities"] as? [String: Any],
              let experimental = capabilities["experimental"] as? [String: Any],
              !experimental.values.allSatisfy({ $0 is String }) else { return body }
        capabilities["experimental"] = nil
        params["capabilities"] = capabilities
        message["params"] = params
        return (try? JSONSerialization.data(withJSONObject: message)) ?? body
    }

    private static func isLoopback(_ origin: String) -> Bool {
        guard let host = URL(string: origin)?.host() else { return false }
        return ["127.0.0.1", "localhost", "::1", "[::1]"].contains(host)
    }
}

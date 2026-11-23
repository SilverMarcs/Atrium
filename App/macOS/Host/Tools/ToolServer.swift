import AtriumProtocol
import Foundation

/// The host's MCP server: one set of tools, which the agents this Mac runs
/// reach on the agent bridge and paired agents such as ChatGPT reach through
/// their gateway and the relay. Each message is answered on its own, with no
/// session kept between them.
///
/// What a caller may use depends only on its credential, and is checked when
/// listing the tools and again when calling one, so a tool that isn't listed
/// can't be called either.
@MainActor
final class ToolServer {
    /// Who sends a message, from how it reached the host.
    enum Credential {
        /// An agent this Mac runs, with the bridge's token.
        case localAgent
        /// A paired device of the agent kind, through its gateway, with what the user let it do.
        case paired(ClientDevice, AgentAccess)
    }

    /// Who may use a tool.
    struct Audience: OptionSet {
        let rawValue: Int
        static let localAgents = Audience(rawValue: 1)
        static let paired = Audience(rawValue: 2)
    }

    struct Tool {
        let name: String
        let description: String
        /// The JSON schema's properties, and the ones it requires.
        let properties: [String: Any]
        var required: [String] = []
        let audience: Audience
        /// Whether Settings lets local agents use it right now.
        var isEnabled: (IntegrationSettings) -> Bool = { _ in true }
        /// Asks Claude to load it with the session rather than behind its
        /// tool search, for a tool an agent must not miss.
        var alwaysLoads = false
        /// Changes nothing, so a paired agent that may only read can use it.
        var readsOnly = false
        let run: (ToolCall) async throws -> String
    }

    /// One call to a tool, with who made it.
    struct ToolCall {
        let arguments: [String: Any]
        let credential: Credential
        /// The session a local agent calls from, as far as the host can tell.
        let caller: String?

        var isLocal: Bool {
            if case .localAgent = credential { true } else { false }
        }
    }

    /// A failure the caller should read, as the tool's result.
    struct Failure: Error {
        let message: String
        init(_ message: String) { self.message = message }
    }

    /// What agents call this server, which names its tools to them, such as Claude's `mcp__atrium__show_page`.
    nonisolated static let name = "atrium"
    static let protocolVersions = ["2025-11-25", "2025-06-18", "2025-03-26"]

    private let settings: IntegrationSettings
    /// The session a local agent's tool call comes from, given the call's `_meta`.
    private let resolveCaller: ([String: Any]) async -> String?
    private var tools: [Tool] = []

    init(settings: IntegrationSettings, resolveCaller: @escaping ([String: Any]) async -> String?) {
        self.settings = settings
        self.resolveCaller = resolveCaller
    }

    func register(_ tools: [Tool]) {
        self.tools += tools
    }

    /// The tools a credential may use now.
    func tools(for credential: Credential) -> [Tool] {
        tools.filter { allows($0, for: credential) }
    }

    private func allows(_ tool: Tool, for credential: Credential) -> Bool {
        switch credential {
        case .localAgent: tool.audience.contains(.localAgents) && tool.isEnabled(settings)
        case .paired(_, let access): tool.audience.contains(.paired) && (tool.readsOnly || access != .readOnly)
        }
    }

    // MARK: - JSON-RPC

    /// Answers one JSON-RPC message, or returns nil for a notification.
    func handle(_ body: Data, as credential: Credential) async -> Data? {
        guard let message = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              let method = message["method"] as? String else {
            return Self.encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]])
        }
        // Notifications, such as notifications/initialized, need no answer.
        guard let id = message["id"] else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        let response: [String: Any]
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String ?? ""
            response = ["result": [
                "protocolVersion": Self.protocolVersions.contains(requested) ? requested : Self.protocolVersions[0],
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": Self.name, "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1"],
                "instructions": Self.instructions,
            ]]
        case "ping":
            response = ["result": [String: Any]()]
        case "tools/list":
            response = ["result": ["tools": tools(for: credential).map(Self.listing)]]
        case "tools/call":
            response = await call(params, as: credential)
        default:
            response = ["error": ["code": -32601, "message": "Method not found: \(method)"]]
        }
        return Self.encode(response.merging(["jsonrpc": "2.0", "id": id]) { $1 })
    }

    private func call(_ params: [String: Any], as credential: Credential) async -> [String: Any] {
        let name = params["name"] as? String ?? ""
        // A tool the credential may not use is unknown to it, as it isn't listed.
        guard let tool = tools.first(where: { $0.name == name }), allows(tool, for: credential) else {
            return ["error": ["code": -32602, "message": "Unknown tool: \(name)"]]
        }
        var caller: String?
        if case .localAgent = credential {
            caller = await resolveCaller(params["_meta"] as? [String: Any] ?? [:])
        }
        let call = ToolCall(arguments: params["arguments"] as? [String: Any] ?? [:], credential: credential, caller: caller)
        do {
            let text = try await tool.run(call)
            return ["result": ["content": [["type": "text", "text": text]]]]
        } catch {
            let message = (error as? Failure)?.message ?? error.localizedDescription
            return ["result": ["content": [["type": "text", "text": message]], "isError": true]]
        }
    }

    private static func listing(_ tool: Tool) -> [String: Any] {
        var listing: [String: Any] = [
            "name": tool.name,
            "description": tool.description,
            "inputSchema": ["type": "object", "properties": tool.properties, "required": tool.required, "additionalProperties": false],
        ]
        if tool.alwaysLoads { listing["_meta"] = ["anthropic/alwaysLoad": true] }
        return listing
    }

    private static func encode(_ object: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
    }

    private static let instructions = """
        Atrium runs Claude, Codex and Antigravity sessions on the user's Mac. Hand work to a session with \
        start_session or send_prompt, then check on it with read_session. Sessions you start are listed in Atrium \
        under your name.
        """
}

// MARK: - Arguments

extension ToolServer.ToolCall {
    func string(_ key: String) -> String? {
        (arguments[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    func required(_ key: String) throws -> String {
        guard let value = string(key) else { throw ToolServer.Failure("Give \(key).") }
        return value
    }

    func bool(_ key: String) -> Bool? {
        arguments[key] as? Bool
    }

    func int(_ key: String) -> Int? {
        (arguments[key] as? NSNumber)?.intValue
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Schema fragments for tool properties.
enum ToolSchema {
    static func string(_ description: String) -> [String: Any] {
        ["type": "string", "description": description]
    }

    static func integer(_ description: String) -> [String: Any] {
        ["type": "integer", "description": description]
    }

    static func boolean(_ description: String) -> [String: Any] {
        ["type": "boolean", "description": description]
    }

    static func strings(_ description: String) -> [String: Any] {
        ["type": "array", "items": ["type": "string"], "description": description]
    }
}

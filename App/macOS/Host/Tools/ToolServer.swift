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
        let reply: (ToolCall) async throws -> Reply
    }

    /// What a tool answers: text, and a picture for one that shows the agent something.
    struct Reply {
        var text: String
        var png: Data?
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

    /// Registers a group of tools that one Settings switch turns on or off together.
    func register(_ tools: [Tool], isEnabled: @escaping (IntegrationSettings) -> Bool) {
        register(tools.map { tool in
            var tool = tool
            tool.isEnabled = isEnabled
            return tool
        })
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
            let reply = try await tool.reply(call)
            var content: [[String: Any]] = [["type": "text", "text": reply.text]]
            if let png = reply.png { content.append(["type": "image", "data": png.base64EncodedString(), "mimeType": "image/png"]) }
            return ["result": ["content": content]]
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

    private static let instructions = "Diffs runs Claude, Codex and Antigravity sessions on the user's Mac."
}

extension ToolServer.Tool {
    /// A tool that answers with text alone.
    init(
        name: String, description: String, properties: [String: Any], required: [String] = [], audience: ToolServer.Audience,
        isEnabled: @escaping (IntegrationSettings) -> Bool = { _ in true }, alwaysLoads: Bool = false, readsOnly: Bool = false,
        run: @escaping (ToolServer.ToolCall) async throws -> String
    ) {
        self.init(
            name: name, description: description, properties: properties, required: required, audience: audience, isEnabled: isEnabled,
            alwaysLoads: alwaysLoads, readsOnly: readsOnly, reply: { ToolServer.Reply(text: try await run($0)) }
        )
    }
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

    func double(_ key: String) -> Double? {
        (arguments[key] as? NSNumber)?.doubleValue
    }

    func strings(_ key: String) -> [String] {
        (arguments[key] as? [String]) ?? (arguments[key] as? String).map { [$0] } ?? []
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

/// Schema fragments for tool properties. A property whose name and type say
/// what it takes needs no description.
enum ToolSchema {
    static func string(_ description: String? = nil) -> [String: Any] { property("string", description) }
    static func integer(_ description: String? = nil) -> [String: Any] { property("integer", description) }
    static func number(_ description: String? = nil) -> [String: Any] { property("number", description) }
    static func boolean(_ description: String? = nil) -> [String: Any] { property("boolean", description) }

    static func strings(_ description: String? = nil) -> [String: Any] {
        property("array", description).merging(["items": ["type": "string"]]) { $1 }
    }

    static func choice(_ values: [String], _ description: String? = nil) -> [String: Any] {
        property("string", description).merging(["enum": values]) { $1 }
    }

    private static func property(_ type: String, _ description: String?) -> [String: Any] {
        var property: [String: Any] = ["type": type]
        if let description { property["description"] = description }
        return property
    }
}

import Foundation

@MainActor
final class CodexBackend: AgentBackend {
    var onEvent: ((AgentEvent) -> Void)?
    var onFailure: ((Error) -> Void)?
    let transport = JSONRPCProcess()
    var sessionID: String?
    var turnID: String?
    var permissions: [String: PermissionPrompt] = [:]
    var questions: [String: QuestionRequest] = [:]
    var subagents: [String: String] = [:]
    var isClosed = false
    var stopRequested = false

    init() {
        transport.onNotification = { [weak self] method, params in
            try self?.receive(method, params: params)
        }
        transport.onRequest = { [weak self] id, method, params in
            if method == "item/tool/requestUserInput" { try self?.ask(id: id, params: params) }
            else { try self?.approve(id: id, method: method, params: params) }
        }
        transport.onFailure = { [weak self] error in self?.onFailure?(error) }
    }

    func initialize(directory: String?) async throws {
        try transport.launch(executable: "codex", arguments: ["app-server", "--listen", "stdio://"], directory: directory)
        _ = try await transport.request("initialize", params: [
            "clientInfo": .object(["name": .string("atrium"), "title": .string("Atrium"), "version": .string(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development")]),
            "capabilities": .object(["experimentalApi": .bool(true)])
        ])
        try transport.notify("initialized")
    }

    func catalog() async throws -> AgentCatalog {
        try await initialize(directory: nil)
        return try await loadCatalog(directory: nil)
    }

    func connect(_ settings: AgentSettings) async throws -> AgentConnection {
        try await initialize(directory: settings.directory)
        let catalog = try await loadCatalog(directory: settings.directory)
        let models = catalog.models
        guard let selected = models.first(where: { $0.rawValue == settings.model })
            ?? models.first(where: { $0.rawValue == catalog.defaultModel }) ?? models.first(where: \.isDefault) ?? models.first else {
            throw AgentError(message: "Codex returned no models")
        }
        let configuredEffort = settings.reasoningLevel.isEmpty && selected.rawValue == catalog.defaultModel ? catalog.defaultReasoningLevel : settings.reasoningLevel
        let effort = selected.reasoningLevels.contains(where: { $0.id == configuredEffort })
            ? configuredEffort : selected.defaultReasoningLevel

        var params: [String: JSONValue] = ["cwd": .string(settings.directory), "model": .string(selected.rawValue), "config": .object(["model_reasoning_effort": effort.isEmpty ? .null : .string(effort)])]
        if catalog.permissionModes.contains(where: { $0.rawValue == settings.permissionMode }) {
            params["permissions"] = .string(settings.permissionMode)
        }
        let method: String
        if let sessionID = settings.sessionID {
            method = "thread/resume"
            params["threadId"] = .string(sessionID)
            params["excludeTurns"] = .bool(true)
        } else { method = "thread/start" }
        let response = try await transport.request(method, params: params)
        let id = try response["thread"].requireString("id")
        sessionID = id
        onEvent?(.session(id, title: response["thread"]["name"].string))
        let activePermission = try permissionProfileID(response)
        guard catalog.permissionModes.contains(where: { $0.rawValue == activePermission }) else {
            throw AgentError(message: "Codex selected an unavailable permission profile: \(response["activePermissionProfile"].raw)")
        }
        return AgentConnection(sessionID: id, catalog: catalog, permissionMode: activePermission, model: try response.requireString("model"), reasoningLevel: response["reasoningEffort"].string ?? effort)
    }

    func send(_ input: AgentInput, settings: AgentSettings) async throws {
        guard let sessionID else { throw AgentError(message: "Codex has no active thread") }
        var params: [String: JSONValue] = ["threadId": .string(sessionID), "input": .array(inputItems(input)), "model": .string(settings.model)]
        if !settings.reasoningLevel.isEmpty { params["effort"] = .string(settings.reasoningLevel) }
        params["permissions"] = .string(settings.permissionMode)
        _ = try await transport.request("turn/start", params: params)
    }

    func stop() async throws {
        guard let sessionID else { throw AgentError(message: "Codex has no active thread") }
        guard let turnID else { stopRequested = true; return }
        stopRequested = false
        _ = try await transport.request("turn/interrupt", params: ["threadId": .string(sessionID), "turnId": .string(turnID)])
    }

    func close() {
        isClosed = true
        transport.close()
        permissions.removeAll()
        questions.removeAll()
        subagents.removeAll()
    }
}

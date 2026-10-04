import Foundation

extension CodexBackend {
    func loadModels() async throws -> [AgentModel] {
        var models: [AgentModel] = []
        var cursor: String?
        repeat {
            var params: [String: JSONValue] = ["includeHidden": .bool(false), "limit": .number(100)]
            if let cursor { params["cursor"] = .string(cursor) }
            let response = try await transport.request("model/list", params: params)
            guard let data = response["data"].array else { throw AgentError(message: "Invalid model catalog: \(response.raw)") }
            for model in data where model["hidden"].bool != true {
                guard let options = model["supportedReasoningEfforts"].array else {
                    throw AgentError(message: "Invalid model reasoning options: \(model.raw)")
                }
                let levels = try options.map { option in
                    ReasoningLevel(id: try option.requireString("reasoningEffort"), description: try option.requireString("description"))
                }
                models.append(AgentModel(
                    rawValue: try model.requireString("model"), name: try model.requireString("displayName"), provider: .codex,
                    reasoningLevels: levels, defaultReasoningLevel: try model.requireString("defaultReasoningEffort"),
                    isDefault: model["isDefault"].bool == true,
                    supportsImages: model["inputModalities"].array?.contains(.string("image")) ?? false
                ))
            }
            let next = response["nextCursor"].string
            guard next == nil || next != cursor else { throw AgentError(message: "Model catalog returned a repeated cursor") }
            cursor = next
        } while cursor != nil
        return models
    }
}

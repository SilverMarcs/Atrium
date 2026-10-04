import Foundation

extension CodexBackend {
    func permissionProfileID(_ response: JSONValue) throws -> String {
        if let id = response["activePermissionProfile"]["id"].string { return id }
        switch response["sandbox"]["type"].string {
        case "readOnly": return ":read-only"
        case "workspaceWrite": return ":workspace"
        case "dangerFullAccess": return ":danger-full-access"
        default: throw AgentError(message: "Unknown Codex permissions: \(response.raw)")
        }
    }

    func loadCatalog(directory: String?) async throws -> AgentCatalog {
        let models = try await loadModels()
        var permissionModes: [PermissionMode] = []
        var cursor: String?
        var seen: Set<String> = []
        repeat {
            var params: [String: JSONValue] = [:]
            if let directory { params["cwd"] = .string(directory) }
            if let cursor { params["cursor"] = .string(cursor) }
            let response = try await transport.request("permissionProfile/list", params: params)
            guard let profiles = response["data"].array else { throw AgentError(message: "Invalid Codex profiles: \(response.raw)") }
            for profile in profiles {
                guard let allowed = profile["allowed"].bool else { throw AgentError(message: "Invalid Codex profile: \(profile.raw)") }
                guard allowed else { continue }
                let id = try profile.requireString("id")
                let label = id.replacing(":", with: "").replacing("-", with: " ").capitalized
                let icon: String
                switch id {
                case ":read-only": icon = "list.clipboard"
                case ":workspace": icon = "lock.shield"
                case ":danger-full-access": icon = "bolt.shield"
                default: icon = "shield"
                }
                permissionModes.append(PermissionMode(rawValue: id, label: label, systemImage: icon, description: profile["description"].string ?? label))
            }
            cursor = response["nextCursor"].string
            if let cursor, !seen.insert(cursor).inserted { throw AgentError(message: "Repeated Codex profile cursor: \(response.raw)") }
        } while cursor != nil
        guard !permissionModes.isEmpty else { throw AgentError(message: "Codex returned no allowed permission profiles") }
        var params: [String: JSONValue] = ["includeLayers": .bool(false)]
        if let directory { params["cwd"] = .string(directory) }
        let config = try await transport.request("config/read", params: params)
        return AgentCatalog(models: models, permissionModes: permissionModes, defaultModel: config["config"]["model"].string ?? models.first(where: \.isDefault)?.rawValue ?? "", defaultReasoningLevel: config["config"]["model_reasoning_effort"].string ?? "")
    }
}

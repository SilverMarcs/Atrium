import AtriumProtocol
import Foundation

/// A session's settings as Antigravity reports them with `session/new`,
/// `session/load` and every `config_option_update`: the model, its thinking
/// level and the agent's mode, each a select config option.
nonisolated struct AntigravitySettings: Equatable {
    var model: String?
    var thinkingLevel: String?
    var mode: String?

    init(model: String? = nil, thinkingLevel: String? = nil, mode: String? = nil) {
        self.model = model
        self.thinkingLevel = thinkingLevel
        self.mode = mode
    }

    init(configOptions: [[String: Any]]) {
        func value(_ id: String) -> String? {
            configOptions.first { $0["id"] as? String == id }?["currentValue"] as? String
        }
        self.init(model: value("model"), thinkingLevel: value("thought_level"), mode: value("mode"))
    }

    /// Atrium's permission mode for the agent's own. Full Access runs in
    /// Default with Atrium allowing what it asks. Antigravity's Plan mode has none.
    func permissionMode(fullAccess: Bool) -> PermissionMode? {
        mode.flatMap(Self.permissionMode).map { $0 == .supervised && fullAccess ? .fullAccess : $0 }
    }

    private static func permissionMode(_ mode: String) -> PermissionMode? {
        switch mode {
        case "default": .supervised
        case "accept-edits": .acceptEdits
        case "auto": .auto
        default: nil
        }
    }

    /// The agent's mode for Atrium's. Antigravity has no mode that never asks,
    /// so Full Access runs in Default and Atrium allows whatever it asks.
    static func mode(for permissionMode: PermissionMode) -> String {
        switch permissionMode {
        case .supervised, .fullAccess: "default"
        case .acceptEdits: "accept-edits"
        case .auto: "auto"
        }
    }

    /// The permission modes chats can use: Antigravity's own that Atrium has
    /// one for, and Full Access, which Atrium gives on top of its Default.
    static func permissionModes(availableModes: [[String: Any]]) -> [PermissionMode] {
        var offered = Set(availableModes.compactMap { ($0["id"] as? String).flatMap(permissionMode) })
        if offered.contains(.supervised) { offered.insert(.fullAccess) }
        return PermissionMode.allCases.filter(offered.contains)
    }

    /// The models a session can switch to, as its model option lists them. A
    /// model has thinking levels when the legacy model list names it once per
    /// level, as `gemini-3.8-flash-high` is.
    static func models(configOptions: [[String: Any]], availableModels: [[String: Any]],
                       permissionModes: [PermissionMode]) -> [AgentModel] {
        let option = configOptions.first { $0["id"] as? String == "model" }
        // The thinking level option is only there while the session runs a model that has one.
        let listed = (configOptions.first { $0["id"] as? String == "thought_level" }?["options"] as? [[String: Any]] ?? [])
            .compactMap { $0["value"] as? String }
        let levels = listed + knownLevels.filter { !listed.contains($0) }
        let legacyIDs = Set(availableModels.compactMap { $0["modelId"] as? String })
        return (option?["options"] as? [[String: Any]] ?? []).compactMap { option in
            guard let id = option["value"] as? String else { return nil }
            let name = option["name"] as? String ?? id
            let efforts = levels.filter { legacyIDs.contains("\(id)-\($0)") }
                .sorted { (knownLevels.firstIndex(of: $0) ?? .max) < (knownLevels.firstIndex(of: $1) ?? .max) }
            return AgentModel(id: id, resolvedID: id, name: name, summary: option["description"] as? String ?? "",
                              reasoningEfforts: efforts, supportsFastMode: false, permissionModes: permissionModes)
        }
    }

    /// Antigravity's thinking levels, lowest first.
    private static let knownLevels = ["minimal", "low", "medium", "high", "xhigh", "max"]
}

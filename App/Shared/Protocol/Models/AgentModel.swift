import Foundation

/// A model an agent can run, as its provider's own model picker lists it.
nonisolated struct AgentModel: Codable, Sendable, Hashable, Identifiable {
    /// What the provider is given to select this model, such as "opus" or "gpt-6.1-sol".
    var id: String
    /// The model tasks report running once this is selected, such as
    /// "claude-opus-5-5" for "opus". The same as `id` for most providers.
    var resolvedID: String
    var name: String
    var summary: String
    /// The reasoning efforts this model accepts, lowest first. Empty when the
    /// model has no effort setting.
    var reasoningEfforts: [String]
    /// Whether fast mode can be turned on with this model. Providers without a
    /// fast mode, and accounts that aren't allowed it, never offer it.
    var supportsFastMode: Bool
    /// The permission modes chats can use with this model on this host, as
    /// the provider and its settings allow. Nil from a host that doesn't say.
    var permissionModes: [PermissionMode]?

    /// How a reasoning effort reads in menus, such as "Extra High" for "xhigh".
    static func effortName(_ effort: String) -> String {
        switch effort {
        case "xhigh": "Extra High"
        default: effort.capitalized
        }
    }
}

nonisolated extension Sequence<AgentModel> {
    /// The model a task reports running: the one selected by that name, or
    /// else the first that resolves to it.
    func model(running model: String?) -> AgentModel? {
        guard let model else { return nil }
        return first { $0.id == model } ?? first { $0.resolvedID == model }
    }

    /// The permission modes a chat running a model can use: that model's, or
    /// any model's while the chat's model isn't known. Nil when the host doesn't say.
    func permissionModes(running model: String?) -> [PermissionMode]? {
        if let modes = self.model(running: model)?.permissionModes { return modes }
        let listed = compactMap(\.permissionModes)
        guard !listed.isEmpty else { return nil }
        return PermissionMode.allCases.filter { mode in listed.contains { $0.contains(mode) } }
    }
}

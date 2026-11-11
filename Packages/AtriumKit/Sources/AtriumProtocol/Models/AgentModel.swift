import Foundation

/// A model an agent can run, as its provider's own model picker lists it.
public nonisolated struct AgentModel: Codable, Sendable, Hashable, Identifiable {
    /// What the provider is given to select this model, such as "opus" or "gpt-6.1-sol".
    public var id: String
    /// The model tasks report running once this is selected, such as
    /// "claude-opus-5-5" for "opus". The same as `id` for most providers.
    public var resolvedID: String
    public var name: String
    public var summary: String
    /// The reasoning efforts this model accepts, lowest first. Empty when the
    /// model has no effort setting.
    public var reasoningEfforts: [String]
    /// Whether fast mode can be turned on with this model. Providers without a
    /// fast mode, and accounts that aren't allowed it, never offer it.
    public var supportsFastMode: Bool

    public init(
        id: String,
        resolvedID: String,
        name: String,
        summary: String,
        reasoningEfforts: [String],
        supportsFastMode: Bool
    ) {
        self.id = id
        self.resolvedID = resolvedID
        self.name = name
        self.summary = summary
        self.reasoningEfforts = reasoningEfforts
        self.supportsFastMode = supportsFastMode
    }

    /// How a reasoning effort reads in menus, such as "Extra High" for "xhigh".
    public static func effortName(_ effort: String) -> String {
        switch effort {
        case "xhigh": "Extra High"
        default: effort.capitalized
        }
    }
}

public nonisolated extension Sequence<AgentModel> {
    /// The model a task reports running: the one selected by that name, or
    /// else the first that resolves to it.
    func model(running model: String?) -> AgentModel? {
        guard let model else { return nil }
        return first { $0.id == model } ?? first { $0.resolvedID == model }
    }
}

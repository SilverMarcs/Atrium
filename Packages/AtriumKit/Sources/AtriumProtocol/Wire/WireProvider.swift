import Foundation

public nonisolated struct WireProvider: Codable, Sendable, Hashable, Identifiable {
    public var provider: AgentProvider
    public var isEnabled: Bool
    /// Set while the provider couldn't load its tasks.
    public var error: String?
    /// The models tasks can switch to, once the host has listed them. Absent
    /// for providers whose model can't be changed from Atrium.
    public var models: [AgentModel]?
    /// The provider's own defaults, used to label a new chat before it exists.
    public var defaultSettings: TaskStartSettings?
    /// What deleting one of its tasks removes, for the confirmation.
    public var deletionMessage: String

    public init(
        provider: AgentProvider,
        isEnabled: Bool,
        error: String? = nil,
        models: [AgentModel]? = nil,
        defaultSettings: TaskStartSettings? = nil,
        deletionMessage: String
    ) {
        self.provider = provider
        self.isEnabled = isEnabled
        self.error = error
        self.models = models
        self.defaultSettings = defaultSettings
        self.deletionMessage = deletionMessage
    }

    public var id: AgentProvider { provider }
}

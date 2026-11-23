import Foundation

nonisolated struct WireProvider: Codable, Sendable, Hashable, Identifiable {
    var provider: AgentProvider
    /// Its command-line client is installed on the host, which is all it takes to use it.
    var isAvailable: Bool
    /// Set while the provider couldn't load its tasks.
    var error: String?
    /// The models tasks can switch to, once the host has listed them. Absent
    /// for providers whose model can't be changed from Atrium.
    var models: [AgentModel]?
    /// The provider's own defaults, used to label a new chat before it exists.
    var defaultSettings: TaskStartSettings?
    /// What deleting one of its tasks removes, for the confirmation.
    var deletionMessage: String

    init(
        provider: AgentProvider,
        isAvailable: Bool,
        error: String? = nil,
        models: [AgentModel]? = nil,
        defaultSettings: TaskStartSettings? = nil,
        deletionMessage: String
    ) {
        self.provider = provider
        self.isAvailable = isAvailable
        self.error = error
        self.models = models
        self.defaultSettings = defaultSettings
        self.deletionMessage = deletionMessage
    }

    private enum CodingKeys: String, CodingKey {
        case provider, isAvailable, error, models, defaultSettings, deletionMessage
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        provider = try container.decode(AgentProvider.self, forKey: .provider)
        isAvailable = container.lenient(.isAvailable, or: false)
        error = container.lenient(.error, or: nil)
        models = container.lenient(.models, or: nil)
        defaultSettings = container.lenient(.defaultSettings, or: nil)
        deletionMessage = container.lenient(.deletionMessage, or: "")
    }

    private enum EncodingKeys: String, CodingKey {
        case provider, isAvailable, isEnabled, error, models, defaultSettings, deletionMessage
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: EncodingKeys.self)
        try container.encode(provider, forKey: .provider)
        try container.encode(isAvailable, forKey: .isAvailable)
        // Older clients require isEnabled; clients already on the newer release require isAvailable.
        try container.encode(isAvailable, forKey: .isEnabled)
        try container.encodeIfPresent(error, forKey: .error)
        try container.encodeIfPresent(models, forKey: .models)
        try container.encodeIfPresent(defaultSettings, forKey: .defaultSettings)
        try container.encode(deletionMessage, forKey: .deletionMessage)
    }

    var id: AgentProvider { provider }
}

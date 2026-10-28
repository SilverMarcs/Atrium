import Foundation

nonisolated struct WireProvider: Codable, Sendable, Hashable, Identifiable {
    var provider: AgentProvider
    var isEnabled: Bool
    /// Set while the provider couldn't load its tasks.
    var error: String?
    /// The models tasks can switch to, once the host has listed them. Absent
    /// for providers whose model can't be changed from Atrium.
    var models: [AgentModel]?
    /// What deleting one of its tasks removes, for the confirmation.
    var deletionMessage: String

    var id: AgentProvider { provider }
}

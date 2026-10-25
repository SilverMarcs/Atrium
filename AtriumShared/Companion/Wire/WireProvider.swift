import Foundation

nonisolated struct WireProvider: Codable, Sendable, Hashable, Identifiable {
    var provider: AgentProvider
    var isEnabled: Bool
    /// Set while the provider couldn't load its tasks.
    var error: String?

    var id: AgentProvider { provider }
}

import Foundation

/// How full a conversation keeps its model's context, counted the way its
/// provider's own interface counts it.
struct AgentContextUsage: Codable, Sendable, Equatable {
    var tokens: Int
    /// The tokens the model can take in at once, once the provider has said.
    var window: Int?

    var usedPercent: Int? {
        guard let window, window > 0 else { return nil }
        return min(100, Int((Double(tokens) / Double(window) * 100).rounded()))
    }
}

import Foundation

/// How much of its model's context a conversation uses, counted the way its
/// provider's own interface counts it.
nonisolated struct WireContextUsage: Codable, Sendable, Hashable {
    var tokens: Int
    /// The tokens the model can take in at once.
    var window: Int

    var usedPercent: Int {
        guard window > 0 else { return 0 }
        return min(100, Int((Double(tokens) / Double(window) * 100).rounded()))
    }
}

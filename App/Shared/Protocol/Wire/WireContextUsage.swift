import Foundation

/// How much of its model's context a conversation uses, counted the way its
/// provider's own interface counts it.
public nonisolated struct WireContextUsage: Codable, Sendable, Hashable {
    public var tokens: Int
    /// The tokens the model can take in at once.
    public var window: Int

    public init(tokens: Int, window: Int) {
        self.tokens = tokens
        self.window = window
    }

    public var usedPercent: Int {
        guard window > 0 else { return 0 }
        return min(100, Int((Double(tokens) / Double(window) * 100).rounded()))
    }
}

import Foundation

public nonisolated struct AgentDecision: Codable, Sendable, Hashable {
    public var allowed: Bool
    public var answers: [String: [String]] = [:]

    public init(allowed: Bool, answers: [String: [String]] = [:]) {
        self.allowed = allowed
        self.answers = answers
    }
}

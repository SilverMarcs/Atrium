import Foundation

nonisolated struct AgentDecision: Codable, Sendable, Hashable {
    var allowed: Bool
    var answers: [String: [String]] = [:]
}

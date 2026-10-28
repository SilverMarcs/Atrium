import Foundation

/// A pending agent decision. The provider retains the context needed to send its answer.
nonisolated struct AgentInteraction: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var taskID: String
    var title: String
    var detail: String
    var questions: [AgentQuestion] = []
    var supportsResponse = true
}

import Foundation

/// A pending agent decision. The provider retains the protocol request until it is answered.
nonisolated struct AgentInteraction: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var taskID: String
    var title: String
    var detail: String
    var questions: [AgentQuestion] = []
    var supportsResponse = true
}

import Foundation

nonisolated struct AgentQuestion: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var title: String
    var options: [String]
    var allowsMultiple = false
    var isSecret = false
    var optionDescriptions: [String: String] = [:]
}

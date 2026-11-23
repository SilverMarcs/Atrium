import Foundation

nonisolated struct AgentQuestion: Codable, Sendable, Hashable, Identifiable {
    var id: String
    var title: String
    var options: [String]
    var allowsMultiple: Bool = false
    var isSecret: Bool = false
    var optionDescriptions: [String: String] = [:]
    /// Markdown shown under the question, such as what a secret is for and a
    /// link to where it's found.
    var note: String?
}

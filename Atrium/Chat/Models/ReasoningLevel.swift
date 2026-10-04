import Foundation

struct ReasoningLevel: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let description: String

    var name: String { id.capitalized }
}

import Foundation

struct AgentModel: Codable, Hashable, Identifiable, Sendable {
    let rawValue: String
    let name: String
    let provider: AgentProvider
    let reasoningLevels: [ReasoningLevel]
    let defaultReasoningLevel: String
    let isDefault: Bool
    let supportsImages: Bool

    var id: String { rawValue }
    var imageName: String { provider.imageName }
}

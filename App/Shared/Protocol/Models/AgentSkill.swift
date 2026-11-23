import Foundation

/// A skill the task's provider can invoke in its current project.
public nonisolated struct AgentSkill: Codable, Sendable, Hashable, Identifiable {
    public let name: String
    public let description: String

    public var id: String { name }

    public init(name: String, description: String) {
        self.name = name
        self.description = description
    }
}

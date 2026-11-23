import Foundation

/// A skill the task's provider can invoke in its current project.
nonisolated struct AgentSkill: Codable, Sendable, Hashable, Identifiable {
    let name: String
    let description: String

    var id: String { name }
}

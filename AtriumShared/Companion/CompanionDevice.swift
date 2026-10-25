import Foundation

/// How a paired phone identifies itself. The id is stable per install.
nonisolated struct CompanionDevice: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var name: String
}

import Foundation

/// How a paired client identifies itself. The id is stable per install.
nonisolated struct ClientDevice: Codable, Sendable, Hashable, Identifiable {
    var id: UUID
    var name: String
}

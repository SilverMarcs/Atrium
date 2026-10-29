import Foundation

/// How a paired client identifies itself. The id is stable per install.
public nonisolated struct ClientDevice: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String

    public init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }
}

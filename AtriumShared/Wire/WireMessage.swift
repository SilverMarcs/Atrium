import Foundation

public struct WireMessage: Codable, Sendable, Identifiable, Hashable {
    public enum Role: String, Codable, Sendable { case user, assistant }

    public var id: UUID
    public var role: Role
    public var turnIndex: Int
    public var blocks: [WireBlock]

    public init(id: UUID, role: Role, turnIndex: Int, blocks: [WireBlock]) {
        self.id = id
        self.role = role
        self.turnIndex = turnIndex
        self.blocks = blocks
    }
}

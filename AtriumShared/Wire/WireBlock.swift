import Foundation

public struct WireBlock: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        case text
        case toolCall
    }

    public var id: UUID
    public var kind: Kind
    public var text: String
    public var toolSymbolName: String?

    public init(id: UUID, kind: Kind, text: String = "", toolSymbolName: String? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.toolSymbolName = toolSymbolName
    }
}

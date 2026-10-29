/// One styled terminal row, addressed independently of scrollback eviction.
public nonisolated struct WireTerminalLine: Codable, Sendable, Equatable {
    public var row: Int
    public var content: String
    public var isWrapped: Bool

    public init(row: Int, content: String, isWrapped: Bool = false) {
        self.row = row
        self.content = content
        self.isWrapped = isWrapped
    }
}

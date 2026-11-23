import Foundation

/// What a saved command printed, as plain text lines numbered from when its
/// output was last cleared. Only the last line can still change, so a client
/// that has the earlier lines gets just the rest.
public nonisolated struct WireCommandOutput: Codable, Sendable, Equatable {
    /// How many lines a host keeps for each command; older ones are dropped.
    public static let maximumLines = 3000

    /// Changes whenever the output is cleared, which numbers lines from zero again.
    public var id: UUID
    /// The number of the oldest line the host still keeps.
    public var firstLine: Int
    /// The number of the first line in `lines`. A change replaces every line
    /// from here on; a complete output starts at `firstLine`.
    public var start: Int
    public var lines: [String]

    public init(id: UUID, firstLine: Int, start: Int, lines: [String]) {
        self.id = id
        self.firstLine = firstLine
        self.start = start
        self.lines = lines
    }

    /// The number one past the last line.
    public var end: Int { start + lines.count }

    /// The lines from `line` on, for a client that has everything before it.
    public func changes(from line: Int) -> Self {
        let start = min(max(line, self.start), end)
        return Self(id: id, firstLine: firstLine, start: start, lines: Array(lines[(start - self.start)...]))
    }

    /// The complete output after this change, or nil when it doesn't follow
    /// from `previous`, which takes subscribing again.
    public func applying(to previous: Self?) -> Self? {
        guard firstLine >= 0, start >= firstLine, lines.count <= Self.maximumLines else { return nil }
        guard start > firstLine else { return self }
        guard let previous, previous.id == id, previous.start <= firstLine, previous.end >= start else { return nil }
        let kept = previous.lines[(firstLine - previous.start)..<(start - previous.start)]
        return Self(id: id, firstLine: firstLine, start: firstLine, lines: kept + lines)
    }
}

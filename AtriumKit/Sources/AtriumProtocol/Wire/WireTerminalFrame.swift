import Foundation

/// A copied task terminal screen. Rows carry display-only ANSI styling, never
/// the original process's queries, clipboard requests, or notification escapes.
public nonisolated struct WireTerminalFrame: Codable, Sendable, Equatable {
    public static let scrollbackRows = 500
    public static let maximumBytes = 4 * 1024 * 1024

    public var terminalID: UUID
    public var sequence: UInt64
    /// Nil for a complete checkpoint; otherwise the checkpoint this changes.
    public var baseSequence: UInt64?
    public var columns: Int
    public var rows: Int
    public var firstRow: Int
    public var screenRow: Int
    public var cursorRow: Int
    public var cursorColumn: Int
    public var isAlternate: Bool
    public var inputModes: String
    public var hasExited: Bool
    public var exitCode: Int32?
    public var lines: [WireTerminalLine]

    public init(terminalID: UUID, sequence: UInt64, columns: Int, rows: Int,
                firstRow: Int, screenRow: Int, cursorRow: Int, cursorColumn: Int,
                isAlternate: Bool, inputModes: String, hasExited: Bool,
                exitCode: Int32? = nil, lines: [WireTerminalLine]) {
        self.terminalID = terminalID
        self.sequence = sequence
        self.columns = columns
        self.rows = rows
        self.firstRow = firstRow
        self.screenRow = screenRow
        self.cursorRow = cursorRow
        self.cursorColumn = cursorColumn
        self.isAlternate = isAlternate
        self.inputModes = inputModes
        self.hasExited = hasExited
        self.exitCode = exitCode
        self.lines = lines
    }

    public func changes(since previous: Self?) -> Self {
        guard let previous, terminalID == previous.terminalID,
              columns == previous.columns, rows == previous.rows,
              isAlternate == previous.isAlternate else { return self }
        let old = Dictionary(uniqueKeysWithValues: previous.lines.map { ($0.row, $0) })
        var delta = self
        delta.baseSequence = previous.sequence
        delta.lines = lines.filter { old[$0.row] != $0 }
        return delta
    }

    /// A gap or a different process requires a fresh checkpoint. Never draw a
    /// partial terminal after a route change or apply late output to its restart.
    public func applying(to previous: Self?) -> Self? {
        guard (1...1000).contains(columns), (1...500).contains(rows),
              firstRow >= 0, screenRow >= firstRow,
              screenRow - firstRow <= Self.scrollbackRows,
              screenRow <= Int.max - rows,
              (screenRow..<(screenRow + rows)).contains(cursorRow),
              (0...columns).contains(cursorColumn), inputModes.utf8.count <= 256,
              lines.count <= Self.scrollbackRows + rows,
              lines.reduce(0, { $0 + $1.content.utf8.count }) <= Self.maximumBytes else { return nil }
        let range = firstRow..<(screenRow + rows)
        var retained: [Int: WireTerminalLine] = [:]
        if let baseSequence {
            guard let previous, previous.terminalID == terminalID,
                  previous.sequence == baseSequence, sequence > baseSequence,
                  previous.columns == columns, previous.rows == rows,
                  previous.isAlternate == isAlternate else { return nil }
            retained = Dictionary(uniqueKeysWithValues: previous.lines.filter { range.contains($0.row) }.map { ($0.row, $0) })
        }
        var seen = Set<Int>()
        for line in lines {
            guard range.contains(line.row), seen.insert(line.row).inserted else { return nil }
            retained[line.row] = line
        }
        guard retained.count == range.count,
              retained.values.reduce(0, { $0 + $1.content.utf8.count }) <= Self.maximumBytes else { return nil }
        var result = self
        result.baseSequence = nil
        result.lines = retained.values.sorted { $0.row < $1.row }
        return result
    }
}

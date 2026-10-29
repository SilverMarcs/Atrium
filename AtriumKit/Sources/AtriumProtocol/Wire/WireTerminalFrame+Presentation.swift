import Foundation

public nonisolated extension WireTerminalFrame {
    /// Display commands only. The companion never replays the host's PTY queries.
    func presentation(since previous: Self?) -> String {
        let cursor = "\u{1B}[\(cursorRow - screenRow + 1);\(min(cursorColumn, columns - 1) + 1)H"
        let finish = "\u{1B}[0m\u{1B}[?7h" + cursor + inputModes
        guard let previous, previous.terminalID == terminalID,
              previous.columns == columns, previous.rows == rows,
              previous.isAlternate == isAlternate,
              screenRow - firstRow >= previous.screenRow - previous.firstRow,
              screenRow >= previous.screenRow, screenRow - previous.screenRow < rows else {
            return checkpointPresentation() + finish
        }
        let old = Dictionary(uniqueKeysWithValues: previous.lines.map { ($0.row, $0) })
        // Edits to already scrolled-off history (or a clear/reflow) require a checkpoint.
        if lines.contains(where: { $0.row < previous.screenRow && old[$0.row] != $0 }) {
            return checkpointPresentation() + finish
        }
        var result = "\u{1B}[0m\u{1B}[r\u{1B}[?6l\u{1B}[?7l"
        let scrolled = screenRow - previous.screenRow
        if scrolled > 0 {
            // Finish rows that left the live screen before moving them into history.
            for line in lines where line.row >= previous.screenRow && line.row < screenRow && old[line.row] != line {
                result += position(line.row - previous.screenRow) + "\u{1B}[2K" + line.content
            }
            result += position(rows - 1) + String(repeating: "\r\n", count: scrolled)
        }
        for line in lines where line.row >= screenRow {
            if old[line.row] != line || line.row >= previous.screenRow + rows {
                result += position(line.row - screenRow) + "\u{1B}[2K" + line.content
            }
        }
        return result + finish
    }

    private func checkpointPresentation() -> String {
        var result = "\u{1B}c\u{1B}[3J\u{1B}[H\u{1B}[2J"
        if isAlternate { result += "\u{1B}[?1049h\u{1B}[H\u{1B}[2J" }
        for (index, line) in lines.enumerated() {
            if index > 0, !line.isWrapped { result += "\r\n" }
            result += line.content
        }
        return result
    }

    private func position(_ row: Int) -> String { "\u{1B}[\(row + 1);1H" }
}

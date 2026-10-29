import AtriumProtocol
import Foundation
import SwiftTerm

/// Copies the host's parsed display. No process queries or side-effecting OSC
/// commands cross the wire, and an attaching viewer sees the current screen.
@MainActor
struct TerminalScreenCapture {
    private var cachedRows: [Int: (source: TerminalContentRowSnapshot, line: WireTerminalLine)] = [:]

    mutating func frame(from terminal: Terminal, sequence: UInt64) -> WireTerminalFrame? {
        guard let view = terminal.localProcessTerminalView as? AppTerminalView,
              (1...1000).contains(view.terminalDimensions.cols),
              (1...500).contains(view.terminalDimensions.rows),
              let snapshot = view.terminalContentSnapshot(region: .history(maximumScrollbackRows: WireTerminalFrame.scrollbackRows)) else { return nil }
        let input = snapshot.inputState
        let modes = "\u{1B}[?1\(input.applicationCursor ? "h" : "l")"
            + "\u{1B}\(input.applicationKeypad ? "=" : ">")"
            + "\u{1B}[?2004\(input.bracketedPasteMode ? "h" : "l")"
            + "\u{1B}[?1004\(input.focusReportingEnabled ? "h" : "l")"
            + "\u{1B}[=\(input.keyboardEnhancementFlags.rawValue)u"
            + "\u{1B}[?25\(view.isCursorVisible ? "h" : "l")"
        var nextRows: [Int: (source: TerminalContentRowSnapshot, line: WireTerminalLine)] = [:]
        var lines = snapshot.rows.map { row in
            let line: WireTerminalLine
            if let cached = cachedRows[row.absoluteRow], cached.source == row {
                line = cached.line
            } else {
                line = WireTerminalLine(row: row.absoluteRow, content: Self.styled(row.cells), isWrapped: row.isWrapped)
            }
            nextRows[row.absoluteRow] = (row, line)
            return line
        }
        cachedRows = nextRows
        var bytes = lines.reduce(0) { $0 + $1.content.utf8.count }
        // A giant styled history must not crowd out the current screen.
        while bytes > WireTerminalFrame.maximumBytes, let first = lines.first,
              first.row < snapshot.liveTopRow {
            bytes -= first.content.utf8.count
            lines.removeFirst()
        }
        guard bytes <= WireTerminalFrame.maximumBytes, let first = lines.first else { return nil }
        return WireTerminalFrame(
            terminalID: terminal.id, sequence: sequence,
            columns: input.dimensions.cols, rows: input.dimensions.rows,
            firstRow: first.row, screenRow: snapshot.liveTopRow,
            cursorRow: min(max(snapshot.cursorRow, snapshot.liveTopRow), snapshot.liveTopRow + input.dimensions.rows - 1),
            cursorColumn: min(max(snapshot.cursorColumn, 0), input.dimensions.cols - 1),
            isAlternate: input.isAlternateBuffer, inputModes: modes,
            hasExited: terminal.hasExited, exitCode: terminal.lastExitCode, lines: lines
        )
    }

    private static func styled(_ cells: [TerminalCellSnapshot]) -> String {
        var result = "\u{1B}[0m"
        var attribute = Attribute.empty
        let end = cells.lastIndex { cell in
            let styledBackground: Bool = switch cell.attribute.bg {
            case .ansi256, .trueColor: true
            case .defaultColor, .defaultInvertedColor: false
            }
            return styledBackground || !cell.attribute.style.isEmpty
                || cell.text.unicodeScalars.contains { $0.value >= 0x20 }
        }.map { $0 + 1 } ?? 0
        for cell in cells.prefix(end) where cell.width > 0 {
            if cell.attribute != attribute {
                attribute = cell.attribute
                result += sgr(attribute)
            }
            // Captured cells are display text, never executable terminal escapes.
            let text = String(String.UnicodeScalarView(cell.text.unicodeScalars.filter {
                $0.value >= 0x20 && !((0x7F...0x9F).contains($0.value))
            }))
            result += text.isEmpty ? " " : text
        }
        return result + "\u{1B}[0m"
    }

    private static func sgr(_ attribute: Attribute) -> String {
        var codes = ["0"]
        let styles: [(CharacterStyle, String)] = [
            (.bold, "1"), (.dim, "2"), (.italic, "3"), (.blink, "5"),
            (.inverse, "7"), (.invisible, "8"), (.crossedOut, "9")
        ]
        for (style, code) in styles where attribute.style.contains(style) { codes.append(code) }
        if attribute.underlineStyle != .none { codes.append("4:\(attribute.underlineStyle.rawValue)") }
        else if attribute.style.contains(.underline) { codes.append("4") }
        codes.append(color(attribute.fg, channel: 38))
        codes.append(color(attribute.bg, channel: 48))
        if let underline = attribute.underlineColor { codes.append(color(underline, channel: 58)) }
        return "\u{1B}[" + codes.joined(separator: ";") + "m"
    }

    private static func color(_ color: Attribute.Color, channel: Int) -> String {
        switch color {
        case .ansi256(let code): "\(channel);5;\(code)"
        case .trueColor(let red, let green, let blue): "\(channel);2;\(red);\(green);\(blue)"
        case .defaultColor, .defaultInvertedColor: "\(channel + 1)"
        }
    }
}

import AtriumProtocol
import Foundation

/// A command's output as plain text, read from what it writes to its terminal.
///
/// Programs draw on a line at a time: carriage returns, backspaces and
/// erasing redraw the current line, as progress bars do, and a newline moves
/// on to the next. Colors and other escape sequences are dropped. Moving the
/// cursor up, as full-screen programs do, isn't followed, so they show only
/// what they print line by line.
nonisolated struct CommandOutput: Sendable {
    /// The longest line kept before it wraps onto the next.
    static let maximumLineLength = 1000

    private(set) var id = UUID()
    /// The number of the oldest line kept.
    private(set) var firstLine = 0
    /// Lines that ended with a newline, which no longer change.
    private var lines: [String] = []
    private var current: [Unicode.Scalar] = []
    private var column = 0
    /// Whether the program asked for application cursor keys, which arrow keys
    /// are sent as instead.
    private(set) var usesApplicationCursorKeys = false
    private var state = State.text
    /// The end of a UTF-8 character split across reads.
    private var partial: [UInt8] = []

    private enum State {
        case text
        case escape
        /// Escapes such as `ESC ( B` take one more character.
        case escapeArgument
        case controlSequence(String)
        /// Operating system commands and device strings, which run until a terminator.
        case string
        case stringEscape
    }

    var wire: WireCommandOutput {
        WireCommandOutput(id: id, firstLine: firstLine, start: firstLine,
                          lines: current.isEmpty ? lines : lines + [String(String.UnicodeScalarView(current))])
    }

    var isEmpty: Bool { lines.isEmpty && current.isEmpty }

    mutating func clear() {
        self = CommandOutput(usesApplicationCursorKeys: usesApplicationCursorKeys)
    }

    private init(usesApplicationCursorKeys: Bool) {
        self.usesApplicationCursorKeys = usesApplicationCursorKeys
    }

    init() {}

    /// Adds a line of Atrium's own, such as the command a run starts, on a line of its own.
    mutating func appendLine(_ line: String) {
        if !current.isEmpty { newline() }
        current = Array(line.unicodeScalars)
        newline()
    }

    /// Adds what the program wrote, returning whether it rang the terminal bell.
    @discardableResult
    mutating func append(_ data: Data) -> Bool {
        var bytes = partial + [UInt8](data)
        partial = Self.incompleteSuffix(of: bytes)
        bytes.removeLast(partial.count)
        var rang = false
        for scalar in String(decoding: bytes, as: UTF8.self).unicodeScalars {
            if read(scalar) { rang = true }
        }
        return rang
    }

    /// Takes one character, returning whether it was the bell.
    private mutating func read(_ scalar: Unicode.Scalar) -> Bool {
        switch state {
        case .text:
            switch scalar {
            case "\u{1B}": state = .escape
            case "\u{07}": return true
            case "\n", "\u{0B}", "\u{0C}": newline()
            case "\r": column = 0
            case "\u{08}": column = max(column - 1, 0)
            case "\t": move(to: (column / 8 + 1) * 8)
            case "\u{9B}": state = .controlSequence("")
            case "\u{9D}", "\u{90}": state = .string
            default:
                // Other control characters print nothing.
                if scalar.value >= 0x20, !(0x7F...0x9F).contains(scalar.value) { write(scalar) }
            }
        case .escape:
            switch scalar {
            case "[": state = .controlSequence("")
            case "]", "P", "X", "^", "_": state = .string
            case "(", ")", "*", "+", "#", "%": state = .escapeArgument
            case "c":
                clear()
                state = .text
            default: state = .text
            }
        case .escapeArgument:
            state = .text
        case .controlSequence(let parameters):
            if (0x40...0x7E).contains(scalar.value) {
                state = .text
                perform(Character(scalar), parameters: parameters)
            } else if parameters.count < 64 {
                state = .controlSequence(parameters + String(scalar))
            }
        case .string:
            if scalar == "\u{07}" || scalar == "\u{9C}" { state = .text }
            else if scalar == "\u{1B}" { state = .stringEscape }
        case .stringEscape:
            state = scalar == "\\" ? .text : .string
        }
        return false
    }

    private mutating func perform(_ command: Character, parameters: String) {
        let values = parameters.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) }
        let first = values.first.flatMap(\.self)
        switch command {
        case "K":
            switch first ?? 0 {
            case 0: current.removeSubrange(min(column, current.count)...)
            case 1: current.replaceSubrange(0..<min(column + 1, current.count), with: repeatElement(" ", count: min(column + 1, current.count)))
            default: current.removeAll()
            }
        case "G", "`": move(to: max((first ?? 1) - 1, 0))
        case "C": move(to: column + max(first ?? 1, 1))
        case "D": column = max(column - max(first ?? 1, 1), 0)
        case "J" where first == 2 || first == 3: clear()
        case "h", "l":
            // Private modes are listed after "?", as in `ESC [ ? 1 h`.
            if parameters.hasPrefix("?"), parameters.dropFirst().split(separator: ";").contains("1") {
                usesApplicationCursorKeys = command == "h"
            }
        default: break
        }
    }

    private mutating func write(_ scalar: Unicode.Scalar) {
        if column >= Self.maximumLineLength { newline() }
        if column < current.count {
            current[column] = scalar
        } else {
            current += repeatElement(" ", count: column - current.count)
            current.append(scalar)
        }
        column += 1
    }

    private mutating func move(to column: Int) {
        self.column = min(column, Self.maximumLineLength)
    }

    private mutating func newline() {
        while current.last == " " { current.removeLast() }
        lines.append(String(String.UnicodeScalarView(current)))
        current.removeAll()
        column = 0
        let excess = lines.count - (WireCommandOutput.maximumLines - 1)
        if excess > 0 {
            lines.removeFirst(excess)
            firstLine += excess
        }
    }

    /// The bytes at the end that start a UTF-8 character without finishing it.
    private static func incompleteSuffix(of bytes: [UInt8]) -> [UInt8] {
        guard !bytes.isEmpty else { return [] }
        for length in 1...min(3, bytes.count) {
            let byte = bytes[bytes.count - length]
            guard byte & 0xC0 == 0x80 else {
                let needed = byte >= 0xF0 ? 4 : byte >= 0xE0 ? 3 : byte >= 0xC0 ? 2 : 1
                return needed > length ? Array(bytes.suffix(length)) : []
            }
        }
        return []
    }
}

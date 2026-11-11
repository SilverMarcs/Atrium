import Highlightr
import SwiftUI
import UIKit

/// Colours code with Highlightr, the engine and themes the chat's Markdown
/// code blocks use, so code reads the same everywhere. A pass over a whole
/// file runs highlight.js and can take a while, so it stays off the main
/// actor, and Highlightr isn't safe to use from two threads at once.
actor CodeHighlighter {
    static let shared = CodeHighlighter()

    private var highlighters: [Bool: Highlightr] = [:]

    /// Each line's colours, highlighted together so comments and strings that
    /// span lines are coloured whole; nil when Highlightr can't colour them.
    func colors(of lines: [String], language: String, isDark: Bool) -> [AttributedString]? {
        let source = lines.joined(separator: "\n")
        guard let highlighted = highlighter(isDark: isDark)?.highlight(source, as: language, fastRender: true),
              highlighted.string == source
        else { return nil }
        var location = 0
        return lines.map { line in
            let range = NSRange(location: location, length: line.utf16.count)
            location += range.length + 1
            return colored(highlighted.attributedSubstring(from: range))
        }
    }

    private func highlighter(isDark: Bool) -> Highlightr? {
        if let highlighter = highlighters[isDark] { return highlighter }
        let highlighter = Highlightr()
        highlighter?.setTheme(to: isDark ? "atom-one-dark" : "atom-one-light")
        highlighters[isDark] = highlighter
        return highlighter
    }

    /// Only the colours carry over; the view sets the font.
    private func colored(_ line: NSAttributedString) -> AttributedString {
        var result = AttributedString(line.string)
        line.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: line.length)) { value, range, _ in
            guard let color = value as? UIColor, let range = Range(range, in: result) else { return }
            result[range].foregroundColor = Color(uiColor: color)
        }
        return result
    }
}

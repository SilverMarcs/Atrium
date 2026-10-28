import Foundation
import SwiftUI

/// Very small regex-based highlighter for the code files and diffs show.
/// Aimed at Swift first but the patterns are general enough to look
/// reasonable on JS/Python/Go/etc. — strings, numbers, comments, and a shared
/// keyword list. Order matters: comments are applied last so they win over
/// any keyword/string coloring that fell inside them.
enum CodeHighlighter {
    private static let keywords: Set<String> = [
        // Swift
        "let", "var", "func", "if", "else", "for", "while", "switch", "case",
        "return", "import", "struct", "class", "enum", "protocol", "extension",
        "public", "private", "internal", "fileprivate", "static", "final",
        "override", "init", "self", "Self", "true", "false", "nil", "guard",
        "do", "try", "catch", "throw", "throws", "rethrows", "async", "await",
        "where", "in", "is", "as", "break", "continue", "default",
        "fallthrough", "repeat", "typealias", "associatedtype", "operator",
        "indirect", "lazy", "weak", "unowned", "mutating", "nonmutating",
        "convenience", "required", "open", "some", "any", "Any",
        // Common across other languages
        "function", "const", "def", "from", "package", "interface", "type",
        "new", "delete", "void", "null", "undefined", "this", "super",
        "lambda", "yield", "with", "pass", "raise", "elif", "and", "or", "not"
    ]

    /// Compiled once, as every visible line is highlighted on its own.
    private static let rules: [(NSRegularExpression, Color)] = [
        ("\\b(" + keywords.map { NSRegularExpression.escapedPattern(for: $0) }.joined(separator: "|") + ")\\b", .pink),
        (#"\b\d+(?:\.\d+)?\b"#, .purple),
        (#""(?:\\.|[^"\\])*""#, .orange),
        (#"//.*"#, .secondary),
        (#"#.*"#, .secondary),
    ].compactMap { pattern, color in
        (try? NSRegularExpression(pattern: pattern)).map { ($0, color) }
    }

    static func highlight(_ source: String) -> AttributedString {
        var attrs = AttributedString(source)
        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
        for (regex, color) in rules {
            regex.enumerateMatches(in: source, range: nsRange) { match, _, _ in
                guard let match,
                      let swiftRange = Range(match.range, in: source)
                else { return }
                let startOffset = source.distance(from: source.startIndex, to: swiftRange.lowerBound)
                let endOffset = source.distance(from: source.startIndex, to: swiftRange.upperBound)
                let start = attrs.index(attrs.startIndex, offsetByCharacters: startOffset)
                let end = attrs.index(attrs.startIndex, offsetByCharacters: endOffset)
                attrs[start..<end].foregroundColor = color
            }
        }
        return attrs
    }
}

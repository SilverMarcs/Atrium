import Foundation
import SwiftUI

/// Very small regex-based highlighter used by the diff view. Aimed at
/// Swift first but the patterns are general enough to look reasonable on
/// JS/Python/Go/etc. — strings, numbers, comments, and a shared keyword
/// list. Order matters: comments are applied last so they win over any
/// keyword/string coloring that fell inside them.
enum DiffSyntaxHighlighter {
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

    private static let keywordColor = Color.pink
    private static let stringColor = Color.orange
    private static let numberColor = Color.purple
    private static let commentColor = Color.secondary

    static func highlight(_ source: String) -> AttributedString {
        var attrs = AttributedString(source)

        let keywordPattern = "\\b(" + keywords
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|") + ")\\b"
        apply(pattern: keywordPattern, in: source, attrs: &attrs, color: keywordColor)
        apply(pattern: #"\b\d+(?:\.\d+)?\b"#, in: source, attrs: &attrs, color: numberColor)
        apply(pattern: #""(?:\\.|[^"\\])*""#, in: source, attrs: &attrs, color: stringColor)
        apply(pattern: #"//.*"#, in: source, attrs: &attrs, color: commentColor)
        apply(pattern: #"#.*"#, in: source, attrs: &attrs, color: commentColor)

        return attrs
    }

    private static func apply(
        pattern: String,
        in source: String,
        attrs: inout AttributedString,
        color: Color
    ) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
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
}

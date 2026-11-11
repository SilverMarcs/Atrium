import Foundation
import Observation

/// Lines of a file or diff hunk as `CodeLinesView` shows them, with their
/// syntax colours once a background pass has made them.
@MainActor @Observable
final class CodeListing: Identifiable {
    let lines: [CodeLine]
    /// Each line's colours, in order; nil shows plain text.
    private(set) var colors: [AttributedString]?
    /// Sizes the code column, so rows not yet loaded keep the same width.
    let longestLine: String
    /// Sizes the gutter, so every row's numbers line up.
    let widestNumber: String
    private let language: String?
    private var colorsAreDark: Bool?

    init(lines: [CodeLine], fileName: String) {
        self.lines = lines
        longestLine = lines.max { $0.text.utf16.count < $1.text.utf16.count }?.text ?? ""
        widestNumber = lines.compactMap(\.number).max().map(String.init) ?? ""
        language = CodeLanguage.highlightName(forFileNamed: fileName)
    }

    func highlight(isDark: Bool) async {
        guard let language, colorsAreDark != isDark else { return }
        let colors = await CodeHighlighter.shared.colors(of: lines.map(\.text), language: language, isDark: isDark)
        guard let colors, !Task.isCancelled else { return }
        self.colors = colors
        colorsAreDark = isDark
    }
}

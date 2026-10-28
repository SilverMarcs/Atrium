import SwiftUI

/// Highlighted lines of code beside their numbers, shared by file previews
/// and diffs. The code scrolls sideways under a fixed gutter, as wide as its
/// longest line so rows not yet loaded keep the same width, and both columns
/// load lazily within the enclosing vertical scroll view.
struct CodeLinesView: View {
    let lines: [CodeLine]
    /// A line number to mark, as from a search match.
    var markedLine: Int?
    private let longestLine: String
    private let widestNumber: String
    @State private var codeWidth: CGFloat = 0

    init(lines: [CodeLine], markedLine: Int? = nil) {
        self.lines = lines
        self.markedLine = markedLine
        longestLine = lines.max { $0.text.utf16.count < $1.text.utf16.count }?.text ?? ""
        widestNumber = lines.compactMap(\.number).max().map(String.init) ?? ""
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            LazyVStack(alignment: .trailing, spacing: 0) {
                ForEach(lines) { line in
                    // The widest number, hidden, keeps every row's gutter the same width.
                    Text(widestNumber)
                        .hidden()
                        .overlay(alignment: .trailing) {
                            if let number = line.number {
                                Text(number, format: .number.grouping(.never))
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        .padding(.leading, 8)
                        .padding(.trailing, 4)
                        .padding(.vertical, 1)
                        .background(background(for: line))
                        .id(line.number ?? -line.id)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            ScrollView(.horizontal) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        Text(CodeHighlighter.highlight(line.text))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(background(for: line))
                    }
                }
                .background(alignment: .topLeading) {
                    Text(longestLine)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 8)
                        .hidden()
                        .onGeometryChange(for: CGFloat.self, of: \.size.width) { codeWidth = $0 }
                }
                .containerRelativeFrame(.horizontal, alignment: .leading) { length, _ in max(length, codeWidth) }
            }
            .scrollIndicators(.hidden)
        }
        .font(.footnote.monospaced())
    }

    private func background(for line: CodeLine) -> Color {
        switch line.kind {
        case .added: .green.opacity(0.2)
        case .removed: .red.opacity(0.2)
        case nil: line.number != nil && line.number == markedLine ? .accentColor.opacity(0.15) : .clear
        }
    }
}

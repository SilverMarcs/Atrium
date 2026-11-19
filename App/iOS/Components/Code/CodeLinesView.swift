import SwiftUI

/// Highlighted lines of code beside their numbers, shared by file previews
/// and diffs. The code scrolls sideways under a fixed gutter, as wide as its
/// longest line so rows not yet loaded keep the same width, and both columns
/// load lazily within the enclosing vertical scroll view.
struct CodeLinesView: View {
    let listing: CodeListing
    /// A line number to mark, as from a search match.
    var markedLine: Int?
    @State private var codeWidth: CGFloat = 0
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            LazyVStack(alignment: .trailing, spacing: 0) {
                ForEach(listing.lines) { line in
                    LineNumberLabel(line: line, listing: listing)
                        .padding(.vertical, 1)
                        .background(line.background(markedLine: markedLine))
                        // A diff's removed and added lines can share a number,
                        // and two rows with one ID leave one of them blank.
                        .id(line.id)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            ScrollView(.horizontal) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(listing.lines) { line in
                        Text(listing.colors?[line.id] ?? AttributedString(line.text))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 8)
                            .padding(.vertical, 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(line.background(markedLine: markedLine))
                    }
                }
                .background(alignment: .topLeading) {
                    Text(listing.longestLine)
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
        .task(id: HighlightPass(listing: ObjectIdentifier(listing), colorScheme: colorScheme)) {
            await listing.highlight(isDark: colorScheme == .dark)
        }
    }
}

/// A line's number in the gutter, right-aligned in the width of the
/// listing's widest number, so every row's gutter is the same width.
struct LineNumberLabel: View {
    let line: CodeLine
    let listing: CodeListing

    var body: some View {
        Text(listing.widestNumber)
            .hidden()
            .overlay(alignment: .trailing) {
                if let number = line.number {
                    Text(number, format: .number.grouping(.never))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 4)
    }
}

extension CodeLine {
    /// The line's tint: added, removed, a side-by-side blank, or the marked line.
    func background(markedLine: Int? = nil) -> Color {
        switch kind {
        case .added: .green.opacity(0.2)
        case .removed: .red.opacity(0.2)
        case nil where isFiller: .primary.opacity(0.04)
        case nil: number != nil && number == markedLine ? .accentColor.opacity(0.15) : .clear
        }
    }
}

/// Highlights again for a new listing or appearance.
private struct HighlightPass: Hashable {
    let listing: ObjectIdentifier
    let colorScheme: ColorScheme
}

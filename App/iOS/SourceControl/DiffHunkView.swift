import SwiftUI

/// One hunk: its header, then its lines with their numbers, scrolling
/// sideways together so wide code stays readable. Side by side, the old
/// lines sit left of the new ones, row for row, wrapping instead.
struct DiffHunkView: View {
    let hunk: FileDiffHunk
    let layout: DiffLayout

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(hunk.header)
                .font(.footnote.monospaced())
                .foregroundStyle(.tint)
                .padding(.horizontal, 8)
            switch layout {
            case .unified:
                CodeLinesView(listing: hunk.unified)
            case .sideBySide:
                SideBySideLinesView(old: hunk.old, new: hunk.new)
            }
        }
    }
}

/// A hunk's old and new lines in two columns. Long lines wrap, and each row
/// is as tall as its taller side, so a row's two lines stay level.
private struct SideBySideLinesView: View {
    let old: CodeListing
    let new: CodeListing
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(old.lines.indices, id: \.self) { index in
                HStack(spacing: 0) {
                    cell(old, at: index)
                    Divider()
                    cell(new, at: index)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.footnote.monospaced())
        .task(id: colorScheme) {
            await old.highlight(isDark: colorScheme == .dark)
            await new.highlight(isDark: colorScheme == .dark)
        }
    }

    private func cell(_ listing: CodeListing, at index: Int) -> some View {
        let line = listing.lines[index]
        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            LineNumberLabel(line: line, listing: listing)
            Text(listing.colors?[line.id] ?? AttributedString(line.text))
                .padding(.horizontal, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(line.background())
    }
}

/// A hunk's lines as each layout shows them, kept so their highlighting
/// survives redraws and layout switches.
struct FileDiffHunk: Identifiable {
    let header: String
    let unified: CodeListing
    let old: CodeListing
    let new: CodeListing

    var id: ObjectIdentifier { ObjectIdentifier(unified) }

    init(_ hunk: DiffHunk, fileName: String) {
        header = hunk.header
        unified = CodeListing(lines: CodeLine.lines(of: hunk), fileName: fileName)
        let columns = CodeLine.sideBySideLines(of: hunk)
        old = CodeListing(lines: columns.old, fileName: fileName)
        new = CodeListing(lines: columns.new, fileName: fileName)
    }
}

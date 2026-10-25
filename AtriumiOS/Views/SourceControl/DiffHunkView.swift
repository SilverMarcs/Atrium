import SwiftUI

/// One hunk. Lines scroll sideways together so wide code stays readable and
/// the colored backgrounds span the widest line.
struct DiffHunkView: View {
    let hunk: DiffHunk

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(hunk.header)
                .font(.footnote.monospaced())
                .foregroundStyle(.tint)
                .padding(.horizontal, 8)
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(hunk.lines) { line in
                        Text(DiffSyntaxHighlighter.highlight(line.content))
                            .font(.footnote.monospaced())
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(background(for: line.kind))
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .scrollIndicators(.hidden)
        }
    }

    private func background(for kind: GitDiffLineKind?) -> Color {
        switch kind {
        case .added: .green.opacity(0.2)
        case .removed: .red.opacity(0.2)
        case nil: .clear
        }
    }
}

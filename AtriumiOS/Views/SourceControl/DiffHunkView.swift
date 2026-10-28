import SwiftUI

/// One hunk: its header, then its lines with their numbers, scrolling
/// sideways together so wide code stays readable.
struct DiffHunkView: View {
    let hunk: DiffHunk

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(hunk.header)
                .font(.footnote.monospaced())
                .foregroundStyle(.tint)
                .padding(.horizontal, 8)
            CodeLinesView(lines: CodeLine.lines(of: hunk))
        }
    }
}

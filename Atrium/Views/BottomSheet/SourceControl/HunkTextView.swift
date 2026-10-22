import SwiftUI

struct HunkTextView: NSViewRepresentable {
    let hunk: DiffHunk
    let fileExtension: String
    @Environment(\.editorFontSize) private var fontSize
    // Observed so `updateNSView` re-fires — and therefore `configure` re-highlights
    // with the correct Xcode light/dark theme — whenever the appearance flips.
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> SharedDiffTextView {
        let textView = SharedDiffTextView()
        configure(textView)
        return textView
    }

    func updateNSView(_ textView: SharedDiffTextView, context: Context) {
        textView.appearance = textView.effectiveAppearance
        configure(textView)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: SharedDiffTextView, context: Context) -> CGSize? {
        guard let layoutManager = nsView.layoutManager, let textContainer = nsView.textContainer else { return nil }
        let width = proposal.width ?? nsView.bounds.width
        guard width > 0 else { return nil }

        let gutterWidth = SharedDiffTextLayout.hunk(fontSize: fontSize).gutterWidth
        let textWidth = max(width - gutterWidth * 2, 50)
        textContainer.containerSize = NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: textContainer)
        let height = layoutManager.usedRect(for: textContainer).height
        return CGSize(width: width, height: max(height, 17))
    }

    private func configure(_ textView: SharedDiffTextView) {
        textView.configure(
            lines: hunk.lines.map {
                SharedDiffLine(
                    content: $0.content,
                    kind: $0.kind,
                    oldLineNumber: $0.oldLineNumber,
                    newLineNumber: $0.newLineNumber
                )
            },
            fileExtension: fileExtension,
            layout: .hunk(fontSize: fontSize),
            width: textView.bounds.width
        )
    }
}

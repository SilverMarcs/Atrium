import SwiftUI

/// Copy and Fork under a finished reply. On Mac they show only while the
/// pointer is over the reply, and their space stays empty until then, so
/// nothing moves; replies scrolling past carry no buttons.
struct ReplyActions: View {
    /// The reply's Markdown, copied as written for plain text and as HTML for
    /// apps that paste rich text.
    let text: String?
    let fork: (() -> Void)?
    #if os(macOS)
    let hover: ReplyHover
    @ScaledMetric private var side: CGFloat = 26
    #else
    @ScaledMetric private var side: CGFloat = 36
    #endif

    var body: some View {
        #if os(macOS)
        if hover.isHovered {
            ReplyActionButtons(text: text, fork: fork, side: side)
        } else {
            Color.clear.frame(height: side)
        }
        #else
        ReplyActionButtons(text: text, fork: fork, side: side)
        #endif
    }
}

#if os(macOS)
/// Whether the pointer is over a reply. Only its actions read it, so moving
/// over replies redraws just their buttons, not their text.
@MainActor @Observable final class ReplyHover {
    var isHovered = false
}
#endif

/// The buttons, each the same square, so Copy turning into a checkmark moves
/// nothing.
private struct ReplyActionButtons: View {
    let text: String?
    let fork: (() -> Void)?
    let side: CGFloat
    @State private var isCopied = false

    var body: some View {
        HStack(spacing: 0) {
            if let text {
                Button(isCopied ? "Copied" : "Copy", systemImage: isCopied ? "checkmark" : "square.on.square") {
                    Pasteboard.copy(text, html: MarkdownHTML.html(from: text))
                    isCopied = true
                }
                .contentTransition(.symbolEffect(.replace))
                .help("Copy")
                .task(id: isCopied) {
                    guard isCopied else { return }
                    try? await Task.sleep(for: .seconds(2))
                    isCopied = false
                }
            }
            if let fork {
                Button("Fork from Here", systemImage: "arrow.triangle.branch", action: fork)
                    .help("Fork from Here")
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(ReplyActionButtonStyle(side: side))
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

/// A square icon button, the same size whichever symbol it shows.
private struct ReplyActionButtonStyle: ButtonStyle {
    let side: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: side, height: side)
            .contentShape(.rect)
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}

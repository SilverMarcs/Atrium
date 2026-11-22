import AtriumProtocol
import SwiftUI

/// How much of the model's context the chat uses, as a thin ring just before
/// the composer's model menu, in the menu's own color. Clicking it shows the
/// share and the token counts.
struct ComposerContextRing: View {
    let usage: WireContextUsage
    @State private var showsDetails = false

    // On the Mac, about as tall as the dictation waveform. On iPhone and
    // iPad, as big as the model menu's gauge symbol beside it, which is 22pt
    // at title2 and follows Dynamic Type up to the
    // xxxLarge cap ComposerModelMenu sets.
    #if os(macOS)
    private let diameter: CGFloat = 14
    private let lineWidth: CGFloat = 2
    #else
    @ScaledMetric(relativeTo: .title2) private var diameter: CGFloat = 22
    @ScaledMetric(relativeTo: .title2) private var lineWidth: CGFloat = 2.5
    #endif
    /// The ring sits in a cell as wide as the dictation button's, spaced from
    /// the model menu as the row's controls are, so the row keeps its rhythm.
    private static let cellWidth = ComposerDictationButton.inlineWidth

    /// The width the ring adds before the model menu.
    static let addedWidth: CGFloat = cellWidth + spacing
    /// The spacing between the ring's cell and the model menu.
    static let spacing = ComposerBarLayout.menuSpacing

    private var fraction: CGFloat { CGFloat(usage.usedPercent) / 100 }

    var body: some View {
        Button {
            showsDetails = true
        } label: {
            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: fraction)
                    .stroke(.secondary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: diameter, height: diameter)
            .frame(width: Self.cellWidth)
            .padding(.vertical, 4)
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .animation(.smooth, value: fraction)
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showsDetails) {
            ContextUsageDetails(usage: usage)
                .presentationCompactAdaptation(.popover)
        }
        .accessibilityLabel("Context")
        .accessibilityValue("\(usage.usedPercent)% used")
    }
}

/// The context popover: the share used, then the tokens against the window.
private struct ContextUsageDetails: View {
    let usage: WireContextUsage

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(usage.usedPercent)% context used")
            Text("\(Self.format(usage.tokens)) / \(Self.format(usage.window)) tokens")
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .fixedSize()
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    /// "618.1K", "1M": the counts as their providers show them.
    private static func format(_ count: Int) -> String {
        count.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
    }
}

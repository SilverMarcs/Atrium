import SwiftUI
#if os(macOS)
import AppKit
#endif

/// A prominent menu label that keeps its indicator beside the selected value.
struct NewChatPickerLabel<Icon: View>: View {
    #if os(macOS)
    @ScaledMetric(relativeTo: .body) private var iconSize = 16 * 1.2
    @ScaledMetric(relativeTo: .body) private var textSize = NSFont.systemFontSize * 1.2
    #else
    @ScaledMetric(relativeTo: .title3) private var iconSize = 24
    #endif
    let title: String
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        HStack {
            Label {
                Text(title)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } icon: {
                icon()
                    .frame(width: iconSize, height: iconSize)
                    .accessibilityHidden(true)
            }
            .labelStyle(.titleAndIcon)
            Image(systemName: "chevron.up.chevron.down")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)
        }
        #if os(macOS)
        .font(.system(size: textSize))
        .padding(.vertical, 7)
        #else
        .font(.title3)
        .frame(minHeight: 53)
        #endif
        .contentShape(.rect)
    }
}

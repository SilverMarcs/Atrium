import SwiftUI

struct MacMarkdownView: View {
    let text: String
    let fontSize: CGFloat
    var isStreaming: Bool = false
    var calculatedHeight: Binding<CGFloat>? = nil

    var body: some View {
        MacMarkdownRepresentable(
            text: text,
            fontSize: fontSize,
            isStreaming: isStreaming,
            calculatedHeight: calculatedHeight
        )
    }
}

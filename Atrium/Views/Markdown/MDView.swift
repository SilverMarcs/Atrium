import SwiftUI

struct MDView: View {
    @AppStorage("fontSize") var fontSize: Double = 13
    var content: String
    var isStreaming: Bool = false
    var calculatedHeight: Binding<CGFloat>? = nil

    var body: some View {
        MacMarkdownRepresentable(
            text: content,
            fontSize: fontSize,
            isStreaming: isStreaming,
            calculatedHeight: calculatedHeight
        )
    }
}

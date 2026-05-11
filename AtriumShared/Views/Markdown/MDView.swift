import SwiftUI
import SwiftMarkdownView

struct MDView: View {
    #if os(macOS)
    private static let defaultFontSize: Double = 13
    #else
    private static let defaultFontSize: Double = 17.5
    #endif

    @AppStorage("fontSize") var fontSize: Double = MDView.defaultFontSize
    var content: String
    var onHeightChange: ((CGFloat) -> Void)? = nil

    var body: some View {
        SwiftMarkdownView(content, onHeightChange: onHeightChange)
            .markdownFontSize(CGFloat(fontSize))
            .markdownCodeTheme(light: "atom-one-light", dark: "atom-one-dark")
    }
}

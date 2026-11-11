import AtriumProtocol
import SwiftUI
import SwiftMarkdownView

/// Renders an agent's Markdown natively with TextKit, the same way LynkChat
/// does: syntax-highlighted code blocks with copy buttons, tables, quotes,
/// lists, headings and images. Images load from the web, or from the task's
/// host for the paths an agent writes, and open in the image viewer when tapped.
struct MarkdownText: View {
    /// Matches LynkChat's default iOS body size so replies read identically.
    #if os(iOS)
    private static let fontSize: CGFloat = 17.5
    #else
    @AppStorage(ChatFontSize.key) private var fontSize = ChatFontSize.default
    #endif
    /// Sharp at a reply's width on any screen.
    private static let imagePixelSize = 1600

    let text: String
    @Environment(\.chatMedia) private var media
    @State private var viewedImage: ViewedImages?
    @Namespace private var namespace

    var body: some View {
        SwiftMarkdownView(text)
            #if os(iOS)
            .markdownFontSize(Self.fontSize)
            #else
            .markdownFontSize(fontSize)
            #endif
            .markdownCodeTheme(light: "atom-one-light", dark: "atom-one-dark")
            // The same path means a different file in another chat or on another host.
            .markdownImageLoader(id: media.map { "\($0.host.id)/\($0.taskID)" } ?? "") { [media] source in
                await MediaSource(source)?.imageData(from: media, maxPixelSize: Self.imagePixelSize)
            }
            .onMarkdownImageTap { source in
                viewedImage = MediaSource(source)?.url(in: media).map { ViewedImages(urls: [$0]) }
            }
            .transaction { $0.animation = nil }
            .imageViewer($viewedImage, namespace: namespace)
    }
}

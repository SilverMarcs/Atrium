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
            .onMarkdownImageTap { tap in
                viewedImage = ViewedImages(tap, in: media)
            }
            .transaction { $0.animation = nil }
            .imageViewer($viewedImage, namespace: namespace)
    }
}

extension ViewedImages {
    /// The tapped image and the rest of its gallery, to swipe between,
    /// leaving out any that can't load. Nil if the tapped one can't.
    @MainActor init?(_ tap: MarkdownImageTap, in media: ChatMedia?) {
        let urls = tap.images.map { MediaSource($0.source)?.url(in: media) }
        guard urls[tap.index] != nil else { return nil }
        self.init(urls: urls.compactMap(\.self), startIndex: urls[..<tap.index].count { $0 != nil })
    }
}

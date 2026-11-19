import AtriumProtocol
import SwiftUI
import WebKit

/// One page an agent showed, loaded from its host into a web page of its own
/// that keeps no data, shows the images it names from the host, and opens
/// links outside the app.
@MainActor
@Observable
final class ChatPageModel {
    enum Phase {
        case loading
        case loaded
        case unavailable
    }

    let webPage: WebPage
    private(set) var phase = Phase.loading
    /// Where the page's own images come from; without a task, the page is unavailable.
    private let files: ChatPageFiles?
    private var html: String?

    init(page: TranscriptPage, media: ChatMedia?, openURL: OpenURLAction) {
        files = media.map { ChatPageFiles(media: $0, pageKey: page.key) }
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        if let files, let scheme = URLScheme(ChatPageFiles.scheme) {
            configuration.urlSchemeHandlers[scheme] = files
        }
        if let scheme = URLScheme(ChatPageSymbols.scheme) {
            configuration.urlSchemeHandlers[scheme] = ChatPageSymbols()
        }
        let scripts = WKUserContentController()
        scripts.addUserScript(WKUserScript(source: ChatPageScripts.theme, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController = scripts
        webPage = WebPage(configuration: configuration, navigationDecider: ChatPageNavigation(document: files?.baseURL, openURL: openURL))
    }

    func load(_ page: TranscriptPage) async {
        guard let files, let html = await files.media.page(page) else {
            phase = .unavailable
            return
        }
        self.html = html
        webPage.load(html: Self.standardsMode(ChatPageFiles.resolvingFileURLs(in: html)), baseURL: files.baseURL)
        phase = .loaded
    }

    /// A page without a doctype would lay out in quirks mode, which the
    /// styles Atrium gives it aren't written for.
    private static func standardsMode(_ html: String) -> String {
        let start = html.trimmingPrefix(while: \.isWhitespace).prefix(9)
        return start.lowercased() == "<!doctype" ? html : "<!doctype html>\n" + html
    }

    #if os(macOS)
    /// Copies the text selected in the page, as the menu's Copy item.
    func copySelection() async {
        guard let text = try? await webPage.callJavaScript("return window.getSelection().toString()") as? String,
              !text.isEmpty else { return }
        Pasteboard.copy(text)
    }
    #endif

    /// The page as the agent wrote it, with its images in it, or a picture of it as it looks here.
    func export(_ format: ChatPageExport.Format, title: String) async throws -> ChatPageExport {
        let data = switch format {
        case .html: await ChatPageExport.html(html ?? "", media: files?.media)
        case .png: try await ChatPageExport.png(of: webPage)
        }
        return ChatPageExport(data: data, format: format, title: title)
    }
}

/// Lets the page itself load and move between its own anchors, and sends
/// every link it follows to the system.
private struct ChatPageNavigation: WebPage.NavigationDeciding {
    /// The page's own URL, which it loads at.
    let document: URL?
    let openURL: OpenURLAction

    func decidePolicy(for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        // Frames inside the page, such as an embedded map, load as they would anywhere.
        if action.target?.isMainFrame == false { return .allow }
        if let document, url.absoluteString.prefix(while: { $0 != "#" }) == document.absoluteString {
            // The page loading, or a link to an anchor in it; reloading it would ask the host for an image.
            return action.navigationType == .other || url.fragment() != nil ? .allow : .cancel
        }
        if ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "") { openURL(url) }
        return .cancel
    }
}

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
    /// The page's height as it lays out, once it has.
    private(set) var contentHeight: CGFloat?
    /// Where the page's own images come from; without a task, the page is unavailable.
    private let files: ChatPageFiles?
    private var html: String?

    /// A page in a sheet has room for side margins, and scrolls sideways on a
    /// screen narrower than the reply it was written for.
    init(media: ChatMedia?, openURL: OpenURLAction, inSheet: Bool = false) {
        files = media.map(ChatPageFiles.init)
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        if let files, let scheme = URLScheme(ChatPageFiles.scheme) {
            configuration.urlSchemeHandlers[scheme] = files
        }
        let scripts = WKUserContentController()
        scripts.addUserScript(WKUserScript(source: ChatPageScripts.theme, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        scripts.addUserScript(WKUserScript(source: ChatPageScripts.height, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if inSheet {
            scripts.addUserScript(WKUserScript(source: ChatPageScripts.sheet, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        configuration.userContentController = scripts
        webPage = WebPage(configuration: configuration, navigationDecider: ChatPageNavigation(document: files?.baseURL, openURL: openURL))
        let reporter = ChatPageHeightReporter()
        scripts.add(reporter, name: ChatPageScripts.heightMessage)
        reporter.onHeight = { [weak self] in self?.contentHeight = $0 }
    }

    func load(_ page: TranscriptPage) async {
        guard let files, let html = await files.media.page(page) else {
            phase = .unavailable
            return
        }
        self.html = html
        webPage.load(html: ChatPageFiles.resolvingFileURLs(in: html), baseURL: files.baseURL)
        phase = .loaded
    }

    #if os(macOS)
    /// Copies the text selected in the page, as the menu's Copy item.
    func copySelection() async {
        guard let text = try? await webPage.callJavaScript("return window.getSelection().toString()") as? String,
              !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
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

/// Holds its model weakly, since the page's scripts keep their handlers.
private final class ChatPageHeightReporter: NSObject, WKScriptMessageHandler {
    var onHeight: ((CGFloat) -> Void)?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let height = message.body as? Double, height > 0 else { return }
        onHeight?(height)
    }
}

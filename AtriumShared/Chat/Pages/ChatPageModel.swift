import AtriumClient
import AtriumProtocol
import SwiftUI
import WebKit

/// One page an agent showed, loaded from its host into a web page of its own
/// that keeps no data and opens links outside the app.
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
    private var html: String?

    /// A page in a sheet has room for side margins, and scrolls sideways on a
    /// screen narrower than the reply it was written for.
    init(openURL: OpenURLAction, inSheet: Bool = false) {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        let scripts = WKUserContentController()
        scripts.addUserScript(WKUserScript(source: ChatPageScripts.theme, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        scripts.addUserScript(WKUserScript(source: ChatPageScripts.height, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if inSheet {
            scripts.addUserScript(WKUserScript(source: ChatPageScripts.sheet, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        configuration.userContentController = scripts
        webPage = WebPage(configuration: configuration, navigationDecider: ChatPageNavigation(openURL: openURL))
        let reporter = ChatPageHeightReporter()
        scripts.add(reporter, name: ChatPageScripts.heightMessage)
        reporter.onHeight = { [weak self] in self?.contentHeight = $0 }
    }

    func load(_ page: TranscriptPage, from host: HostClient?) async {
        guard let html = await host?.page(forKey: page.key) else {
            phase = .unavailable
            return
        }
        self.html = html
        webPage.load(html: html)
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

    /// The page as the agent wrote it, or a picture of it as it looks here.
    func export(_ format: ChatPageExport.Format, title: String) async throws -> ChatPageExport {
        let data = switch format {
        case .html: Data((html ?? "").utf8)
        case .png: try await ChatPageExport.png(of: webPage)
        }
        return ChatPageExport(data: data, format: format, title: title)
    }
}

/// Lets the page itself load and sends every link it follows to the system.
private struct ChatPageNavigation: WebPage.NavigationDeciding {
    let openURL: OpenURLAction

    func decidePolicy(for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .cancel }
        // Frames inside the page, such as an embedded map, load as they would anywhere.
        if action.target?.isMainFrame == false || url.absoluteString == "about:blank" { return .allow }
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

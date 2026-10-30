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

    init(openURL: OpenURLAction) {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        let scripts = WKUserContentController()
        scripts.addUserScript(WKUserScript(source: ChatPageScripts.theme, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        scripts.addUserScript(WKUserScript(source: ChatPageScripts.height, injectionTime: .atDocumentStart, forMainFrameOnly: true))
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
        webPage.load(html: html)
        phase = .loaded
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

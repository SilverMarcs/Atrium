import SwiftUI
import WebKit

extension View {
    /// On Mac, replaces WebKit's own context menu, whose Reload and Back would
    /// blank a page loaded from a string. iOS only offers menus on links and images.
    func chatPageMenu(
        _ model: ChatPageModel,
        expand: (@MainActor () -> Void)? = nil,
        download: (@MainActor (ChatPageExport.Format) -> Void)? = nil
    ) -> some View {
        #if os(macOS)
        webViewContextMenu { element in
            ChatPageMenu(element: element, model: model, expand: expand, download: download)
        }
        #else
        self
        #endif
    }
}

#if os(macOS)
private struct ChatPageMenu: View {
    let element: WebView.ActivatedElementInfo
    let model: ChatPageModel
    let expand: (@MainActor () -> Void)?
    let download: (@MainActor (ChatPageExport.Format) -> Void)?
    @Environment(\.openURL) private var openURL

    var body: some View {
        if let url = element.linkURL {
            Button("Open Link") { openURL(url) }
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.absoluteString, forType: .string)
            }
            Divider()
        }
        Button("Copy") { Task { await model.copySelection() } }
        if let expand {
            Divider()
            Button("Open Full Screen", action: expand)
        }
        if let download {
            Button("Download HTML") { download(.html) }
            Button("Download PNG") { download(.png) }
        }
    }
}
#endif

import AtriumProtocol
import SwiftUI
import WebKit

/// A page an agent showed, beside the chat at the pane's width and scrolling
/// on its own.
struct SidePanePageView: View {
    let page: SidePanePage
    let media: ChatMedia
    @State private var isExpanded = false

    var body: some View {
        Group {
            if let model = page.model, model.phase == .loaded {
                WebView(model.webPage)
                    // Pages leave out their own margins; these scroll with the page.
                    .safeAreaPadding([.horizontal, .top])
                    .webViewContentBackground(.hidden)
                    .scrollBounceBehavior(.basedOnSize)
                    .chatPageMenu(model, expand: { isExpanded = true }, download: { page.download($0) })
            } else if page.model?.phase == .unavailable {
                ContentUnavailableView("Page Unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text("Reconnect to the host and try again."))
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .alert("Couldn’t Save Page", isPresented: Binding {
            page.downloader.exportError != nil
        } set: {
            if !$0 { page.downloader.exportError = nil }
        }) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(page.downloader.exportError ?? "")
        }
        .sheet(isPresented: $isExpanded) {
            if let shown = page.page {
                ChatPageSheet(page: shown)
                    .environment(\.chatMedia, media)
            }
        }
    }
}

/// The pane's download menu, in the toolbar above it.
struct SidePanePageDownloadMenu: View {
    let page: SidePanePage

    var body: some View {
        Menu {
            Button("Download HTML", systemImage: "chevron.left.forwardslash.chevron.right") { page.download(.html) }
            Button("Download PNG", systemImage: "photo") { page.download(.png) }
        } label: {
            Label("Download", systemImage: page.downloader.savedFormat == nil ? "arrow.down" : "checkmark")
                .contentTransition(.symbolEffect(.replace))
        }
        .menuIndicator(.hidden)
        .disabled(!page.isLoaded)
    }
}

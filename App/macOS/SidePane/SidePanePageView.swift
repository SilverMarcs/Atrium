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

/// The pane's controls, together in the toolbar above it.
struct SidePanePageControls: View {
    let page: SidePanePage
    let close: () -> Void

    /// About as wide as the controls themselves, so their item never squeezes them.
    static let minimumWidth: CGFloat = 120
    /// The height of the toolbar's own glass buttons, which these sit among.
    private static let height: CGFloat = 36

    var body: some View {
        HStack(spacing: 16) {
            Button("Close", systemImage: "xmark", action: close)
            Menu {
                Button("Download HTML", systemImage: "chevron.left.forwardslash.chevron.right") { page.download(.html) }
                Button("Download PNG", systemImage: "photo") { page.download(.png) }
            } label: {
                Label("Download", systemImage: page.downloader.savedFormat == nil ? "arrow.down.circle" : "checkmark")
                    .contentTransition(.symbolEffect(.replace))
            }
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(!page.isLoaded)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .menuStyle(.button)
        .imageScale(.large)
        .padding(.horizontal)
        .frame(height: Self.height)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

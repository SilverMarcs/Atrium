import SwiftUI
import WebKit

/// A page an agent showed, inline in its reply at the reply's width and as
/// tall as the page. It never scrolls itself; the chat scrolls past it. On
/// Mac its context menu copies, opens it full screen or downloads it; on
/// iPhone and iPad an Expand button opens it on its own. While the agent is
/// still writing it, a placeholder stands in.
struct ChatPageView: View {
    let page: TranscriptPage

    var body: some View {
        if page.key == nil {
            ChatPagePlaceholder(title: page.title)
        } else {
            ChatPageInline(page: page)
        }
    }
}

private struct ChatPageInline: View {
    let page: TranscriptPage
    @Environment(\.chatMedia) private var media
    @Environment(\.openURL) private var openURL
    @State private var model: ChatPageModel?
    @State private var isExpanded = false
    #if os(macOS)
    @State private var downloadError: String?
    #endif

    /// The page's own height, or the height it had when last shown, capped so
    /// a page sized to the view's height can't keep growing it.
    private var height: CGFloat {
        min(model?.contentHeight ?? ChatPageModel.lastHeight(of: page) ?? 40, 2000)
    }

    var body: some View {
        Group {
            if let model, model.phase == .loaded {
                WebView(model.webPage)
                    .webViewContentBackground(.hidden)
                    // A drag that starts on the page scrolls the chat rather than bouncing the page.
                    .scrollBounceBehavior(.basedOnSize)
                    .chatPageMenu(model, expand: { isExpanded = true }, download: download)
                    #if os(macOS)
                    // A web view keeps the wheel even with nothing to scroll; the chat should get it.
                    .overlay { ScrollWheelPassthrough() }
                    #endif
            } else if model?.phase == .unavailable {
                Label("\(page.title) isn’t available. Reconnect to the host and try again.", systemImage: "exclamationmark.triangle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Color.clear
            }
        }
        .frame(height: model?.phase == .unavailable ? nil : height)
        .frame(maxWidth: .infinity)
        #if os(iOS)
        // Mac opens it from the context menu instead.
        .overlay(alignment: .topTrailing) {
            if model?.phase == .loaded {
                Button("Expand", systemImage: "arrow.up.left.and.arrow.down.right") { isExpanded = true }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .padding(6)
            }
        }
        #endif
        .sheet(isPresented: $isExpanded) {
            ChatPageSheet(page: page)
        }
        #if os(macOS)
        .alert("Couldn’t Save Page", isPresented: Binding {
            downloadError != nil
        } set: {
            if !$0 { downloadError = nil }
        }) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(downloadError ?? "")
        }
        #endif
        .task(id: page.key) {
            // Scrolling back to a page already loaded keeps it, rather than loading it again.
            guard model?.page != page else { return }
            let model = ChatPageModel(page: page, media: media, openURL: openURL, fitsContent: true)
            self.model = model
            await model.load(page)
        }
    }

    #if os(macOS)
    /// Saves the page into Downloads, as a browser would, saying when that fails.
    private var download: (@MainActor (ChatPageExport.Format) -> Void)? {
        guard let model else { return nil }
        let title = page.title
        return { format in
            Task {
                do {
                    _ = try await model.export(format, title: title).saveToDownloads()
                } catch {
                    downloadError = error.localizedDescription
                }
            }
        }
    }
    #else
    private var download: (@MainActor (ChatPageExport.Format) -> Void)? { nil }
    #endif
}

#if os(macOS)
/// Lies over a view and takes only scroll wheel events, handing them up to
/// the scroll view around it; clicks, hovers and menus reach the view below.
private struct ScrollWheelPassthrough: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { WheelCatcher() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class WheelCatcher: NSView {
        /// Takes up-and-down scrolls only: sideways ones still reach the page,
        /// for a wide table or code block in it.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent, event.type == .scrollWheel,
                  abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX) else { return nil }
            return super.hitTest(point)
        }

        override func scrollWheel(with event: NSEvent) {
            if let scrollView = enclosingScrollView {
                scrollView.scrollWheel(with: event)
            } else {
                super.scrollWheel(with: event)
            }
        }
    }
}
#endif

/// Where a page will show once the agent finishes writing it.
private struct ChatPagePlaceholder: View {
    let title: String

    var body: some View {
        Label {
            Text("Preparing \(title)…")
        } icon: {
            ProgressView()
                .controlSize(.small)
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
}

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

    /// The page's own height, capped so a page sized to the view's height
    /// can't keep growing it.
    private var height: CGFloat {
        min(model?.contentHeight ?? 40, 2000)
    }

    var body: some View {
        Group {
            if let model, model.phase == .loaded {
                WebView(model.webPage)
                    .webViewContentBackground(.hidden)
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
                .environment(\.chatMedia, media)
        }
        .task(id: page.key) {
            let model = ChatPageModel(page: page, media: media, openURL: openURL, fitsContent: true)
            self.model = model
            await model.load(page)
        }
    }

    #if os(macOS)
    private var download: (@MainActor (ChatPageExport.Format) -> Void)? {
        guard let model else { return nil }
        let title = page.title
        return { format in
            Task { _ = try? await model.export(format, title: title).saveToDownloads() }
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
        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .scrollWheel ? super.hitTest(point) : nil
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

import AtriumProtocol
import SwiftUI
import WebKit

/// A page an agent showed, on its own and scrollable.
struct ChatPageSheet: View {
    let page: TranscriptPage
    @Environment(\.chatMedia) private var media
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var model: ChatPageModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model, model.phase != .unavailable {
                    WebView(model.webPage)
                        // Pages leave out side margins inline; here they scroll with the page.
                        .safeAreaPadding(.horizontal)
                        .webViewContentBackground(.hidden)
                        .scrollBounceBehavior(.basedOnSize)
                        .chatPageMenu(model)
                } else if model?.phase == .unavailable {
                    ContentUnavailableView("Page Unavailable", systemImage: "exclamationmark.triangle",
                                           description: Text("Reconnect to the host and try again."))
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(page.title)
            #if os(iOS)
            .toolbarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .close) {
                    Button(role: .close) { dismiss() }
                }
            }
        }
        .presentationSizing(.page)
        .task {
            guard model == nil else { return }
            let model = ChatPageModel(media: media, openURL: openURL, inSheet: true)
            self.model = model
            await model.load(page)
        }
    }
}

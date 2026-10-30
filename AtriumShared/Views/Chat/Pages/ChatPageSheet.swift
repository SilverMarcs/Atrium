import AtriumClient
import AtriumProtocol
import SwiftUI
import WebKit

/// A page an agent showed, on its own and scrollable.
struct ChatPageSheet: View {
    let page: TranscriptPage
    @Environment(HostClient.self) private var host: HostClient?
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var model: ChatPageModel?

    var body: some View {
        NavigationStack {
            Group {
                if let model, model.phase != .unavailable {
                    WebView(model.webPage)
                        .webViewContentBackground(.hidden)
                        .scrollBounceBehavior(.basedOnSize)
                        .chatPageMenu(model)
                        // Pages leave out side padding to line up with the reply inline.
                        .padding(.horizontal)
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
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .close) { dismiss() }
                        .keyboardShortcut(.cancelAction)
                }
            }
        }
        .presentationSizing(.page)
        .task {
            guard model == nil else { return }
            let model = ChatPageModel(openURL: openURL)
            self.model = model
            await model.load(page, from: host)
        }
    }
}

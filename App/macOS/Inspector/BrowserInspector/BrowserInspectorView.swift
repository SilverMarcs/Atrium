import SwiftUI

/// The inspector's Browser tab: opens the chat's browser in the pane beside
/// it, the same one its agent drives, or shows what it's on.
struct BrowserInspectorView: View {
    let item: HostTask?
    @Environment(AppModel.self) private var app

    var body: some View {
        if let item, item.host.isLocal {
            if let browser = app.browser(for: item) {
                VStack(spacing: 12) {
                    VStack(spacing: 4) {
                        Text(browser.title.isEmpty ? "Browser" : browser.title)
                            .font(.headline)
                            .lineLimit(2)
                        if let url = browser.url {
                            Text(url.absoluteString)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .multilineTextAlignment(.center)
                    HStack {
                        Button("Show") { app.chatPanes.open(.browser, for: item.id) }
                            .disabled(app.chatPanes.isOpen(for: item.id) && app.chatPanes.current(for: item.id) == .browser)
                        Button("Close") { app.browsers.close(item.task.id) }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Label("No Browser", systemImage: "globe")
                } description: {
                    Text("Open one beside the chat. Its agent uses the same browser.")
                } actions: {
                    Button("Open Browser") { _ = app.browsers.browserOpening(for: item.task.id) }
                }
            }
        } else {
            ContentUnavailableView("No Browser", systemImage: "globe",
                                   description: Text("Chats on this Mac have a browser."))
        }
    }
}

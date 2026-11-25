import SwiftUI
import WebKit

/// A chat's browser in a window of its own, by the chat on this Mac.
struct BrowserWindowItem: Hashable, Codable {
    let taskID: String
}

/// A chat's browser in a window laid out like Safari's: back and forward,
/// the address in the middle, then reload and the page size.
struct BrowserWindow: View {
    let item: BrowserWindowItem
    @Environment(AppModel.self) private var app
    @State private var address = ""
    @FocusState private var isEditing: Bool

    private var browser: AgentBrowser? { app.browsers.browser(for: item.taskID) }
    private var chat: HostTask? {
        app.localHost.flatMap { app.hosts.task(TaskRef(hostID: $0.id, taskID: item.taskID)) }
    }

    var body: some View {
        Group {
            if let browser {
                page(browser)
                    .toolbar { toolbar(browser) }
                    .searchable(text: $address, placement: .toolbarPrincipal, prompt: "Search or enter address")
                    .searchFocused($isEditing)
                    .onSubmit(of: .search) {
                        isEditing = false
                        browser.open(typed: address)
                    }
                    .showsAddress(of: browser.url, in: $address, isEditing: isEditing)
                    .onAppear { browser.isInWindow = true }
                    .onDisappear { browser.isInWindow = false }
            } else {
                ContentUnavailableView("Browser Closed", systemImage: "globe",
                                       description: Text("The chat’s browser closed when the chat was settled or deleted, or after it went unused."))
            }
        }
        // Named for its chat, as the chat's own window is, rather than the page.
        .navigationTitle(chat.map(app.hosts.navigationTitle(for:)) ?? "Browser")
        .navigationSubtitle(chat.map(app.hosts.navigationSubtitle(for:)) ?? "")
        .frame(minWidth: 480, minHeight: 400)
    }

    /// The page, filling the window or at the viewport's size within it, zoomed out to fit.
    private func page(_ browser: AgentBrowser) -> some View {
        BrowserWebView(browser: browser, inWindow: true)
            .padding(browser.viewport == nil ? 0 : 16)
            .ignoresSafeArea(.container, edges: browser.viewport == nil ? .bottom : [])
    }

    @ToolbarContentBuilder
    private func toolbar(_ browser: AgentBrowser) -> some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Back", systemImage: "chevron.left") { Task { try? await browser.goBack() } }
                .disabled(!browser.canGoBack)
            Button("Forward", systemImage: "chevron.right") { Task { try? await browser.goForward() } }
                .disabled(!browser.canGoForward)
        }
        // Shown apart from the buttons, as the inspector's bar shows it, with no glass behind it.
        if browser.isAgentUsing {
            ToolbarItem(placement: .primaryAction) {
                AgentUsingBadge(help: "The agent is using the browser")
            }
            .sharedBackgroundVisibility(.hidden)
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
        ToolbarItem(placement: .primaryAction) {
            BrowserReloadButton(browser: browser)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                BrowserSizeOptions(browser: browser, fitTitle: "Fit Window", fitSymbol: "macwindow")
            } label: {
                Label("Size", systemImage: browser.viewport?.device?.symbol ?? "macwindow")
            }
            .menuIndicator(.hidden)
            .help("Page Size")
        }
    }
}

/// Reload, or Stop while the page loads.
private struct BrowserReloadButton: View {
    let browser: AgentBrowser

    var body: some View {
        if browser.isLoading {
            Button { browser.webView.stopLoading() } label: { BrowserIcon(title: "Stop", symbol: "xmark") }
        } else {
            Button { Task { try? await browser.reload() } } label: { BrowserIcon(title: "Reload", symbol: "arrow.clockwise") }
        }
    }
}

/// A button's symbol at one width, so a round button keeps its size whatever symbol it shows.
private struct BrowserIcon: View {
    let title: String
    let symbol: String

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .frame(width: 18, height: 18)
        }
    }
}

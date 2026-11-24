import SwiftUI
import WebKit

/// A chat's browser beside it: the tab its agent drives, which the user
/// watches and can use too, with an address bar under it. While a window of
/// its own shows the page, this says so instead.
struct InspectorBrowserView: View {
    let browser: AgentBrowser
    let taskID: String
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if browser.isInWindow {
                ContentUnavailableView {
                    Label("Open in a Window", systemImage: "macwindow")
                } actions: {
                    Button("Show Window") { openWindow(value: BrowserWindowItem(taskID: taskID)) }
                }
            } else {
                BrowserWebView(browser: browser)
                    // The same gap from the tab picker as the controls leave below.
                    .padding(.top, 10)
                    .safeAreaBar(edge: .bottom) {
                        HStack {
                            BrowserNavigationButtons(browser: browser)
                            BrowserAddressField(browser: browser)
                            BrowserReloadButton(browser: browser)
                            Button {
                                openWindow(value: BrowserWindowItem(taskID: taskID))
                            } label: {
                                BrowserIcon(title: "Open in Window", symbol: "arrow.up.forward.app")
                            }
                            .help("Open in Window")
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .padding(10)
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shows a chat's own web view, at its viewport's size when it has one. The
/// page goes back to its hidden window when this goes away.
struct BrowserWebView: NSViewRepresentable {
    let browser: AgentBrowser
    /// Shown in the browser's own window, which takes the page from the inspector.
    var inWindow = false

    func makeNSView(context: Context) -> BrowserHostView {
        BrowserHostView()
    }

    func updateNSView(_ host: BrowserHostView, context: Context) {
        _ = browser.viewport
        // While its window is open, the page stays there; the window takes it
        // back once it's marked open, in case the inspector updated in between.
        let windowOpen = browser.isInWindow
        guard inWindow || !windowOpen else { return }
        host.show(browser)
    }
}

struct BrowserNavigationButtons: View {
    let browser: AgentBrowser

    var body: some View {
        ControlGroup {
            Button("Back", systemImage: "chevron.left") { Task { try? await browser.goBack() } }
                .disabled(!browser.canGoBack)
            Button("Forward", systemImage: "chevron.right") { Task { try? await browser.goForward() } }
                .disabled(!browser.canGoForward)
        }
        .fixedSize()
    }
}

struct BrowserReloadButton: View {
    let browser: AgentBrowser

    var body: some View {
        if browser.isLoading {
            Button { browser.webView.stopLoading() } label: { BrowserIcon(title: "Stop", symbol: "xmark") }
        } else {
            Button { Task { try? await browser.reload() } } label: { BrowserIcon(title: "Reload", symbol: "arrow.clockwise") }
        }
    }
}

/// A button's symbol at one width, so the bar's round buttons match whatever symbol they show.
struct BrowserIcon: View {
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

/// The page's address, which takes another address or words to search the web for.
struct BrowserAddressField: View {
    let browser: AgentBrowser
    @State private var address = ""
    @FocusState private var isEditing: Bool

    var body: some View {
        TextField("Address", text: $address, prompt: Text("Search or enter address"))
            .textFieldStyle(.plain)
            .focused($isEditing)
            .onSubmit {
                isEditing = false
                browser.open(typed: address)
            }
            .padding(.horizontal, 12)
            .frame(maxHeight: .infinity)
            .glassEffect(.regular.interactive(), in: .capsule)
            .onChange(of: browser.url, initial: true) {
                if !isEditing { address = browser.url?.absoluteString ?? "" }
            }
            // Leaving the field without going anywhere shows the page's address again.
            .onChange(of: isEditing) {
                if !isEditing { address = browser.url?.absoluteString ?? "" }
            }
    }
}

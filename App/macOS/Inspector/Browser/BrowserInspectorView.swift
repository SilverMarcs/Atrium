import SwiftUI
import WebKit

/// The inspector's Browser tab: an address bar like the other tabs' search
/// bars, over the chat's browser, the tab its agent drives, which the user
/// watches and can use too. Before either has gone anywhere there's only
/// the bar; going somewhere opens the chat's browser. While a window of its
/// own shows the page, this says so instead.
struct BrowserInspectorView: View {
    let item: HostTask?
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    /// Only chats on this Mac have a browser here; others show `RemotePreviewInspector`.
    private var taskID: String? { item.flatMap { $0.host.isLocal ? $0.task.id : nil } }
    private var browser: AgentBrowser? { taskID.flatMap(app.browsers.browser(for:)) }

    var body: some View {
        Group {
            if let browser, let taskID, browser.isInWindow {
                ContentUnavailableView {
                    Label("Open in a Window", systemImage: "macwindow")
                } actions: {
                    Button("Show Window") { openWindow(value: BrowserWindowItem(taskID: taskID)) }
                }
            } else if let browser {
                BrowserWebView(browser: browser)
                    .padding(browser.viewport == nil ? 0 : 12)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaBar(edge: .top) {
            BrowserAddressBar(browser: browser) { typed in
                guard let taskID else { return }
                app.browsers.browserOpening(for: taskID).open(typed: typed)
            } openInWindow: {
                if let taskID { openWindow(value: BrowserWindowItem(taskID: taskID)) }
            }
            .disabled(taskID == nil)
            // As the file tree places its search bar, with the gap its list
            // leaves above its first row.
            .padding(.horizontal, 10)
            .padding(.top, 9)
            .padding(.bottom, 8)
        }
    }
}

/// The inspector's search bar holding the page's address, which takes another
/// address or words to search the web for, with back and forward before it
/// and reload, the page's size and its own window after.
private struct BrowserAddressBar: View {
    let browser: AgentBrowser?
    let open: (String) -> Void
    let openInWindow: () -> Void
    @State private var address = ""
    @State private var isEditing = false

    var body: some View {
        SearchBar(text: $address, placeholder: "Search or enter address", clears: false,
                  onEditingChange: { isEditing = $0 }, onSubmit: { open(address) }) {
            BrowserNavigation(canGoBack: browser?.canGoBack == true, canGoForward: browser?.canGoForward == true) {
                Task { try? await browser?.goBack() }
            } forward: {
                Task { try? await browser?.goForward() }
            }
        } trailing: {
            if browser?.isAgentUsing == true {
                AgentUsingBadge(help: "The agent is using the browser")
            }
            Group {
                // Reload becomes Stop while the page loads.
                if browser?.isLoading == true {
                    BrowserBarButton(title: "Stop", symbol: "xmark") { browser?.webView.stopLoading() }
                } else {
                    BrowserBarButton(title: "Reload", symbol: "arrow.clockwise") { Task { try? await browser?.reload() } }
                }
                if let browser {
                    Menu {
                        BrowserSizeOptions(browser: browser, fitTitle: "Fit Inspector", fitSymbol: "sidebar.trailing")
                    } label: {
                        BrowserBarSymbol(symbol: browser.viewport?.device?.symbol ?? "iphone")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .frame(height: 12)
                    .help("Page Size")
                }
                BrowserBarButton(title: "Open in Window", symbol: "arrow.up.forward.app", action: openInWindow)
            }
            .disabled(browser == nil)
        }
        .animation(.easeOut(duration: 0.2), value: browser?.isAgentUsing)
        .showsAddress(of: browser?.url, in: $address, isEditing: isEditing)
    }

}

/// Back and forward, leading a browser's address bar.
struct BrowserNavigation: View {
    let canGoBack: Bool
    let canGoForward: Bool
    let back: () -> Void
    let forward: () -> Void

    var body: some View {
        ZStack {
            // Holds the bar at the height the other search bars get from their magnifying glass.
            SearchBarIcon()
                .hidden()
            HStack(spacing: 0) {
                BrowserBarButton(title: "Back", symbol: "chevron.left", action: back)
                    .disabled(!canGoBack)
                BrowserBarButton(title: "Forward", symbol: "chevron.right", action: forward)
                    .disabled(!canGoForward)
            }
        }
        .padding(.trailing, 2)
    }
}

/// The yellow sparkles an inspector bar shows while the chat's agent uses what's below it.
struct AgentUsingBadge: View {
    let help: String

    var body: some View {
        Image(systemName: "sparkles")
            .resizable()
            .scaledToFit()
            .frame(width: 13, height: 13)
            .foregroundStyle(.yellow)
            .help(help)
            .transition(.opacity)
    }
}

/// One of the address bar's buttons: a symbol held to one small size, so
/// whichever symbol it shows, the bar keeps the search bars' height.
struct BrowserBarButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            BrowserBarSymbol(symbol: symbol)
        }
        .buttonStyle(.plain)
        .help(title)
    }
}

struct BrowserBarSymbol: View {
    let symbol: String

    var body: some View {
        // Scaled into one box, so a tall phone and a wide arrow look the same size.
        Image(systemName: symbol)
            .resizable()
            .scaledToFit()
            .frame(width: 13, height: 13)
            .foregroundStyle(.secondary)
            .frame(width: 16)
    }
}

/// The sizes pages can lay out at, for a size menu: where the page shows,
/// or a device's, upright or turned.
struct BrowserSizeOptions: View {
    let browser: AgentBrowser
    /// Names fitting wherever the page shows, such as "Fit Window".
    let fitTitle: String
    let fitSymbol: String

    private var device: AgentBrowser.Device? { browser.viewport?.device }

    var body: some View {
        Picker("Size", selection: Binding {
            device
        } set: { device in
            Task { await browser.setViewport(device?.viewport()) }
        }) {
            Label(fitTitle, systemImage: fitSymbol).tag(AgentBrowser.Device?.none)
            ForEach(AgentBrowser.Device.allCases) { device in
                Label("\(device.title) (\(Int(device.size.width))×\(Int(device.size.height)))", systemImage: device.symbol)
                    .tag(Optional(device))
            }
        }
        .pickerStyle(.inline)
        // Turns the device sideways; with no device there's nothing to turn.
        Toggle("Landscape", systemImage: "rotate.right", isOn: Binding {
            browser.viewport?.landscape ?? false
        } set: { landscape in
            guard let device else { return }
            Task { await browser.setViewport(device.viewport(landscape: landscape)) }
        })
        .disabled(device == nil)
    }
}

extension View {
    /// Keeps an address field showing the page's address, except while the
    /// user edits it; leaving it without going anywhere shows the address again.
    func showsAddress(of url: URL?, in address: Binding<String>, isEditing: Bool) -> some View {
        onChange(of: url, initial: true) {
            if !isEditing { address.wrappedValue = url?.absoluteString ?? "" }
        }
        .onChange(of: isEditing) {
            if !isEditing { address.wrappedValue = url?.absoluteString ?? "" }
        }
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

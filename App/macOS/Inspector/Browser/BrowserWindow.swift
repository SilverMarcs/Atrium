import SwiftUI

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
                    .onChange(of: browser.url, initial: true) {
                        if !isEditing { address = browser.url?.absoluteString ?? "" }
                    }
                    .onChange(of: isEditing) {
                        if !isEditing { address = browser.url?.absoluteString ?? "" }
                    }
                    .navigationTitle(browser.title.isEmpty ? "Browser" : browser.title)
                    .onAppear { browser.isInWindow = true }
                    .onDisappear { browser.isInWindow = false }
            } else {
                ContentUnavailableView("Browser Closed", systemImage: "globe",
                                       description: Text("The chat’s browser closed when the chat was settled or deleted."))
                    .navigationTitle("Browser")
            }
        }
        .frame(minWidth: 480, minHeight: 400)
    }

    /// The page, filling the window or at the viewport's size within it, zoomed out to fit.
    private func page(_ browser: AgentBrowser) -> some View {
        BrowserWebView(browser: browser, inWindow: true)
            .padding(browser.viewport == nil ? 0 : 16)
            .ignoresSafeArea(.container, edges: browser.viewport == nil ? .bottom : [])
    }

    private func device(of browser: AgentBrowser) -> AgentBrowser.Device? {
        browser.viewport?.device
    }

    @ToolbarContentBuilder
    private func toolbar(_ browser: AgentBrowser) -> some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button("Back", systemImage: "chevron.left") { Task { try? await browser.goBack() } }
                .disabled(!browser.canGoBack)
            Button("Forward", systemImage: "chevron.right") { Task { try? await browser.goForward() } }
                .disabled(!browser.canGoForward)
        }
        ToolbarItem(placement: .primaryAction) {
            BrowserReloadButton(browser: browser)
        }
        ToolbarItem(placement: .primaryAction) {
            Menu {
                Picker("Size", selection: Binding {
                    device(of: browser)
                } set: { device in
                    Task { await browser.setViewport(device?.viewport()) }
                }) {
                    Label("Fit Window", systemImage: "macwindow").tag(AgentBrowser.Device?.none)
                    ForEach(AgentBrowser.Device.allCases) { device in
                        Label("\(device.title) (\(Int(device.size.width))×\(Int(device.size.height)))", systemImage: device.symbol)
                            .tag(Optional(device))
                    }
                }
                .pickerStyle(.inline)
                Toggle("Landscape", systemImage: "rotate.right", isOn: Binding {
                    browser.viewport?.landscape ?? false
                } set: { landscape in
                    guard let device = device(of: browser) else { return }
                    Task { await browser.setViewport(device.viewport(landscape: landscape)) }
                })
                .disabled(device(of: browser) == nil)
            } label: {
                Label("Size", systemImage: device(of: browser)?.symbol ?? "macwindow")
            }
            .menuIndicator(.hidden)
            .help("Page Size")
        }
    }
}

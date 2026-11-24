import SwiftUI
import WebKit

/// A chat's browser beside it: the tab its agent drives, which the user
/// watches and can use too, filling the pane or at a device's size within it.
struct PaneBrowserView: View {
    let browser: AgentBrowser

    var body: some View {
        BrowserWebView(browser: browser)
            .padding(browser.viewport == nil ? 0 : 16)
            // Filling the pane, the page scrolls on under the toolbar
            // (BrowserHostView insets it); a device's size sits below it.
            .ignoresSafeArea(.container, edges: browser.viewport == nil ? .top : [])
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The browser's part of the pane's toolbar: the address, reload, then the
/// page's size. The pane's own back and forward move between what it shows.
struct PaneBrowserToolbar: ToolbarContent {
    let browser: AgentBrowser

    var body: some ToolbarContent {
        ToolbarItem {
            BrowserAddressField(browser: browser)
        }
        ToolbarItem {
            BrowserReloadButton(browser: browser)
        }
        ToolbarSpacer(.flexible)
        ToolbarItem {
            BrowserSizeMenu(browser: browser)
        }
    }
}

/// Shows a chat's own web view, at its viewport's size when it has one. The
/// page goes back to its hidden window when this goes away.
struct BrowserWebView: NSViewRepresentable {
    let browser: AgentBrowser

    func makeNSView(context: Context) -> BrowserHostView {
        BrowserHostView()
    }

    func updateNSView(_ host: BrowserHostView, context: Context) {
        _ = browser.viewport
        host.show(browser)
    }
}

struct BrowserReloadButton: View {
    let browser: AgentBrowser

    var body: some View {
        if browser.isLoading {
            Button("Stop", systemImage: "xmark") { browser.webView.stopLoading() }
                .help("Stop")
        } else {
            Button("Reload", systemImage: "arrow.clockwise") { Task { try? await browser.reload() } }
                .help("Reload")
        }
    }
}

/// The size pages lay out at: the pane's own, or a device's, upright or turned.
struct BrowserSizeMenu: View {
    let browser: AgentBrowser

    private var device: AgentBrowser.Device? { browser.viewport?.device }

    var body: some View {
        Menu {
            Picker("Size", selection: Binding {
                device
            } set: { device in
                Task { await browser.setViewport(device?.viewport()) }
            }) {
                Label("Fit Pane", systemImage: "rectangle.righthalf.inset.filled").tag(AgentBrowser.Device?.none)
                ForEach(AgentBrowser.Device.allCases) { device in
                    Label("\(device.title) (\(Int(device.size.width))×\(Int(device.size.height)))", systemImage: device.symbol)
                        .tag(Optional(device))
                }
            }
            .pickerStyle(.inline)
            Toggle("Landscape", systemImage: "rotate.right", isOn: Binding {
                browser.viewport?.landscape ?? false
            } set: { landscape in
                guard let device else { return }
                Task { await browser.setViewport(device.viewport(landscape: landscape)) }
            })
            .disabled(device == nil)
        } label: {
            Label("Size", systemImage: device?.symbol ?? "rectangle.righthalf.inset.filled")
        }
        .menuIndicator(.hidden)
        .help("Page Size")
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
            .frame(width: 160)
            .onChange(of: browser.url, initial: true) {
                if !isEditing { address = browser.url?.absoluteString ?? "" }
            }
            // Leaving the field without going anywhere shows the page's address again.
            .onChange(of: isEditing) {
                if !isEditing { address = browser.url?.absoluteString ?? "" }
            }
    }
}

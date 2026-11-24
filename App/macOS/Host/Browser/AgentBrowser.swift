import AppKit
import WebKit

/// One chat's browser: a single tab its agent drives through Atrium's
/// browser tools while the user watches, and can use, in the pane beside the
/// chat. Off screen it sits in a window that's never shown, so real clicks
/// and keys still reach it. A page that opens a sized popup,
/// such as a sign-in window, gets a window of its own.
@MainActor
@Observable
final class AgentBrowser {
    struct ConsoleEntry {
        let sequence: Int
        let level: String
        let text: String
    }

    struct NetworkEntry {
        var sequence = 0
        let id: String
        let method: String
        let url: String
        var kind: String
        var status: Int?
        var type = ""
        var duration: Int?
        var requestBody: String?
        var responseBody: String?
        var error: String?
        /// Where a download was saved.
        var savedTo: String?

        var failed: Bool { error != nil || (status ?? 0) >= 400 || status == 0 }
    }

    /// A size to lay pages out at, as a device would; the page fills its view without one.
    struct Viewport: Equatable {
        var width: Double
        var height: Double
        /// The device it was set as, if any, and which way up.
        var device: Device? = nil
        var landscape = false
    }

    enum Device: String, CaseIterable, Identifiable {
        case iPhoneSE, iPhone, iPhoneProMax, iPadMini, iPad, laptop, desktop

        var id: String { rawValue }

        var title: String {
            switch self {
            case .iPhoneSE: "iPhone SE"
            case .iPhone: "iPhone"
            case .iPhoneProMax: "iPhone Pro Max"
            case .iPadMini: "iPad mini"
            case .iPad: "iPad"
            case .laptop: "Laptop"
            case .desktop: "Desktop"
            }
        }

        var size: CGSize {
            switch self {
            case .iPhoneSE: CGSize(width: 375, height: 667)
            case .iPhone: CGSize(width: 393, height: 852)
            case .iPhoneProMax: CGSize(width: 440, height: 956)
            case .iPadMini: CGSize(width: 744, height: 1133)
            case .iPad: CGSize(width: 820, height: 1180)
            case .laptop: CGSize(width: 1280, height: 800)
            case .desktop: CGSize(width: 1920, height: 1080)
            }
        }

        var symbol: String {
            switch self {
            case .iPhoneSE, .iPhone, .iPhoneProMax: "iphone"
            case .iPadMini, .iPad: "ipad"
            case .laptop: "laptopcomputer"
            case .desktop: "desktopcomputer"
            }
        }

        var userAgent: String? {
            switch self {
            case .iPhoneSE, .iPhone, .iPhoneProMax:
                "Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
            case .iPadMini, .iPad:
                "Mozilla/5.0 (iPad; CPU OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1"
            case .laptop, .desktop: nil
            }
        }

        func viewport(landscape: Bool = false) -> Viewport {
            let size = landscape ? CGSize(width: size.height, height: size.width) : size
            return Viewport(width: size.width, height: size.height, device: self, landscape: landscape)
        }
    }

    let webView: WKWebView
    private(set) var url: URL?
    private(set) var title = ""
    private(set) var isLoading = false
    private(set) var canGoBack = false
    private(set) var canGoForward = false
    /// The size pages lay out at; nil fills wherever the page shows.
    private(set) var viewport: Viewport?

    @ObservationIgnored private(set) var console: [ConsoleEntry] = []
    @ObservationIgnored private(set) var network: [NetworkEntry] = []
    @ObservationIgnored private var pending: [String: NetworkEntry] = [:]
    @ObservationIgnored private var sequence = 0
    /// The last entry the agent saw in a snapshot, and through browser_logs.
    @ObservationIgnored var seenInSnapshot = 0
    @ObservationIgnored var seenInLogs = 0
    /// Requests the page is waiting on, which actions wait for.
    var inflightCount: Int { pending.count }
    /// The agent is acting, so a dialog the page opens is answered for it rather than shown.
    @ObservationIgnored var agentDialogs: (accept: Bool, text: String?)?
    /// Files the agent chose for the next file chooser the page opens; nil once it takes them.
    @ObservationIgnored var pendingUploads: [URL]?
    /// Why the latest navigation failed, until the next one starts.
    @ObservationIgnored fileprivate var loadError: (any Error)?
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private let delegate = BrowserDelegate()
    @ObservationIgnored fileprivate var popups: [BrowserPopup] = []
    /// Where the page sits while no view shows it, so it still takes real events.
    @ObservationIgnored let parking: NSWindow
    /// Atrium's own script world, where the page can't reach the snapshot's element references.
    static let world = WKContentWorld.world(name: "Atrium")

    static let loadTimeout: Duration = .seconds(20)
    private static let maximumEntries = 300
    /// The size a page lays out at off screen with no viewport set.
    static let parkedSize = CGSize(width: 1280, height: 800)

    init() {
        let configuration = WKWebViewConfiguration()
        // Sign-ins last across chats and relaunches, as in a browser.
        configuration.websiteDataStore = .default()
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        let scripts = configuration.userContentController
        scripts.addUserScript(WKUserScript(source: BrowserScripts.page, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        scripts.addUserScript(WKUserScript(source: BrowserScripts.changes, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.world))
        webView = WKWebView(frame: CGRect(origin: .zero, size: Self.parkedSize), configuration: configuration)
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        // Without this, WebKit treats a page no one can see as a background tab:
        // timers slow to about once a second and animation frames stop, so the
        // agent would test a different page than the user sees.
        let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if webView.responds(to: occlusion) { webView.perform(occlusion, with: false as NSNumber) }
        // Off screen, but ordered in: a window that was never shown keeps its page hidden too.
        parking = NSWindow(contentRect: CGRect(x: -10_000, y: -10_000, width: Self.parkedSize.width, height: Self.parkedSize.height),
                           styleMask: [.borderless], backing: .buffered, defer: false)
        parking.isReleasedWhenClosed = false
        parking.ignoresMouseEvents = true
        parking.isExcludedFromWindowsMenu = true
        parking.collectionBehavior = [.transient, .ignoresCycle]
        parking.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) - 1)
        parking.contentView = BrowserHostView()
        parking.orderFrontRegardless()
        delegate.browser = self
        webView.navigationDelegate = delegate
        webView.uiDelegate = delegate
        let handler = MessageHandler { [weak self] name, body in self?.receive(name, body) }
        scripts.add(handler, contentWorld: .page, name: BrowserScripts.consoleHandler)
        scripts.add(handler, contentWorld: .page, name: BrowserScripts.networkHandler)
        observations = [
            webView.observe(\.url) { [weak self] view, _ in MainActor.assumeIsolated { self?.url = view.url } },
            webView.observe(\.title) { [weak self] view, _ in MainActor.assumeIsolated { self?.title = view.title ?? "" } },
            webView.observe(\.isLoading) { [weak self] view, _ in MainActor.assumeIsolated { self?.isLoading = view.isLoading } },
            webView.observe(\.canGoBack) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoBack = view.canGoBack } },
            webView.observe(\.canGoForward) { [weak self] view, _ in MainActor.assumeIsolated { self?.canGoForward = view.canGoForward } },
        ]
        park()
    }

    /// Closes the page and any popups it opened.
    func close() {
        for popup in popups { popup.window.close() }
        popups = []
        webView.stopLoading()
        webView.removeFromSuperview()
        parking.close()
    }

    // MARK: - Where the page shows

    /// Puts the page in its hidden window when no view shows it.
    func park() {
        guard let host = parking.contentView as? BrowserHostView else { return }
        let size = viewport.map { CGSize(width: $0.width, height: $0.height) } ?? Self.parkedSize
        parking.setContentSize(size)
        host.show(self)
    }

    /// Lays the page out in a view showing it: filling it, or at the
    /// viewport's size, zoomed out to fit when the view is smaller.
    func layOut(in bounds: CGRect) {
        guard let viewport else {
            webView.frame = bounds
            if webView.pageZoom != 1 { webView.pageZoom = 1 }
            return
        }
        let scale = min(1, bounds.width / viewport.width, bounds.height / viewport.height)
        let size = CGSize(width: (viewport.width * scale).rounded(), height: (viewport.height * scale).rounded())
        webView.frame = CGRect(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded(),
                               width: size.width, height: size.height)
        if abs(webView.pageZoom - scale) > 0.001 { webView.pageZoom = scale }
    }

    /// Lays pages out at a device's or another size, or fills the view with nil.
    /// A change of device user agent reloads the page, so the site sees it.
    func setViewport(_ viewport: Viewport?) async {
        let userAgent = viewport?.device?.userAgent
        let agentChanged = userAgent != self.viewport?.device?.userAgent
        self.viewport = viewport
        if webView.window === parking { park() } else { webView.superview?.needsLayout = true }
        if agentChanged {
            webView.customUserAgent = userAgent
            if webView.url != nil { try? await reload() }
        }
    }

    /// The size pages lay out at now, in CSS pixels.
    var cssSize: CGSize {
        let zoom = max(webView.pageZoom, 0.01)
        return CGSize(width: (webView.bounds.width / zoom).rounded(), height: (webView.bounds.height / zoom).rounded())
    }

    // MARK: - Navigating

    /// The URL an address names, taking a bare host as https and localhost as
    /// http; nil for anything but a web page or a file.
    static func url(from address: String) -> URL? {
        let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("/") { return URL(filePath: text) }
        let local = text.hasPrefix("localhost") || text.hasPrefix("127.0.0.1") || text.hasPrefix("[::1]")
        let full = text.contains("://") || text.hasPrefix("about:") ? text : (local ? "http://" : "https://") + text
        guard let url = URL(string: full), let scheme = url.scheme?.lowercased(),
              ["http", "https", "file", "about"].contains(scheme) else { return nil }
        return url
    }

    /// What the user typed in an address field: the address it names, or else a web search.
    static func url(fromTyped typed: String) -> URL? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let isAddress = !text.contains(" ") && (text.contains(".") || text.contains(":") || text.hasPrefix("localhost") || text.hasPrefix("/"))
        if isAddress, let url = url(from: text) { return url }
        var search = URLComponents(string: "https://www.google.com/search")
        search?.queryItems = [URLQueryItem(name: "q", value: text)]
        return search?.url
    }

    /// Opens what the user typed in an address field.
    func open(typed: String) {
        guard let url = Self.url(fromTyped: typed) else { return }
        Task { try? await open(url) }
    }

    func open(_ url: URL) async throws {
        try await navigate {
            if url.isFileURL {
                webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
            } else {
                webView.load(URLRequest(url: url))
            }
        }
    }

    func goBack() async throws {
        guard webView.canGoBack else { throw ToolServer.Failure("There's no page to go back to.") }
        try await navigate { webView.goBack() }
    }

    func goForward() async throws {
        guard webView.canGoForward else { throw ToolServer.Failure("There's no page to go forward to.") }
        try await navigate { webView.goForward() }
    }

    func reload() async throws {
        try await navigate { webView.reload() }
    }

    /// Starts a navigation and waits for it to load, or gives up waiting while it still loads.
    private func navigate(_ start: () -> WKNavigation?) async throws {
        loadError = nil
        _ = start()
        try? await Task.sleep(for: .milliseconds(150))
        let deadline = ContinuousClock.now + Self.loadTimeout
        while webView.isLoading, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if let loadError {
            throw ToolServer.Failure("Couldn't load the page: \(loadError.localizedDescription)")
        }
    }

    // MARK: - Console and network

    private func nextSequence() -> Int {
        sequence += 1
        return sequence
    }

    func log(_ level: String, _ text: String) {
        console.append(ConsoleEntry(sequence: nextSequence(), level: level, text: text))
        if console.count > Self.maximumEntries { console.removeFirst(console.count - Self.maximumEntries) }
    }

    func record(_ entry: NetworkEntry) {
        var entry = entry
        entry.sequence = nextSequence()
        network.append(entry)
        if network.count > Self.maximumEntries { network.removeFirst(network.count - Self.maximumEntries) }
    }

    private func receive(_ name: String, _ body: [String: Any]) {
        if name == BrowserScripts.consoleHandler {
            log(body["level"] as? String ?? "log", body["text"] as? String ?? "")
            return
        }
        guard let id = body["id"] as? String else { return }
        let phase = body["phase"] as? String
        var entry = pending.removeValue(forKey: id) ?? NetworkEntry(
            id: id, method: body["method"] as? String ?? "GET", url: body["url"] as? String ?? "", kind: body["kind"] as? String ?? "fetch")
        if let request = body["requestBody"] as? String { entry.requestBody = request }
        if phase == "start" {
            pending[id] = entry
            return
        }
        entry.status = (body["status"] as? NSNumber)?.intValue
        entry.type = body["type"] as? String ?? ""
        entry.duration = (body["duration"] as? NSNumber)?.intValue
        entry.responseBody = body["responseBody"] as? String
        entry.error = body["error"] as? String
        record(entry)
    }

    /// Forgets requests that never answered, as a new page starts loading.
    fileprivate func pageStarted() {
        pending.removeAll()
    }

    // MARK: - Dialogs and popups

    /// Answers a dialog the agent set off as it asked, and notes it for the
    /// agent. Asks the user about any other in a sheet on the window showing
    /// the page, or dismisses it when no one can see the page.
    fileprivate func dialog(_ kind: String, message: String, defaultText: String? = nil) async -> String? {
        if let choice = agentDialogs {
            log("dialog", "\(kind) “\(message)” was \(choice.accept ? "accepted" : "dismissed").")
            return choice.accept ? (choice.text ?? defaultText ?? "") : nil
        }
        guard let window = webView.window, window !== parking, window.isVisible else {
            log("dialog", "\(kind) “\(message)” was dismissed while no one could see the page.")
            return nil
        }
        let alert = NSAlert()
        alert.messageText = message
        let field = NSTextField(string: defaultText ?? "")
        field.frame.size.width = 260
        if kind == "prompt" { alert.accessoryView = field }
        alert.addButton(withTitle: "OK")
        if kind != "alert" { alert.addButton(withTitle: "Cancel") }
        return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    /// The files for a file chooser: those the agent chose, or else the user's pick.
    fileprivate func chooseFiles(_ parameters: WKOpenPanelParameters) async -> [URL]? {
        if let files = pendingUploads {
            pendingUploads = nil
            return parameters.allowsMultipleSelection ? files : Array(files.prefix(1))
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        return await panel.begin() == .OK ? panel.urls : nil
    }

    /// Opens a popup the page asked for in a window of its own, keeping its
    /// link to the page so a sign-in can hand its result back.
    fileprivate func openPopup(configuration: WKWebViewConfiguration, features: WKWindowFeatures) -> WKWebView {
        let size = CGSize(width: features.width?.doubleValue ?? 500, height: features.height?.doubleValue ?? 640)
        let popup = BrowserPopup(configuration: configuration, size: size, delegate: delegate)
        popups.append(popup)
        log("popup", "The page opened a popup window for the user.")
        return popup.webView
    }

    fileprivate func closePopup(_ webView: WKWebView) {
        popups.removeAll { popup in
            guard popup.webView === webView else { return false }
            popup.window.close()
            return true
        }
    }

    /// The addresses of popups open for the user.
    var openPopups: [String] {
        popups.removeAll { !$0.window.isVisible }
        return popups.map { $0.webView.url?.absoluteString ?? "about:blank" }
    }

    // MARK: - Downloads

    /// Where a download goes: the user's Downloads for their own, a scratch
    /// folder for the agent's, so testing doesn't fill Downloads.
    fileprivate func destination(for filename: String) -> URL {
        let folder = agentDialogs == nil
            ? URL.downloadsDirectory
            : FileManager.default.temporaryDirectory.appending(path: "Atrium Browser Downloads", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let base = (filename as NSString).deletingPathExtension, ext = (filename as NSString).pathExtension
        var url = folder.appending(path: filename)
        var number = 2
        while FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            url = folder.appending(path: ext.isEmpty ? "\(base) \(number)" : "\(base) \(number).\(ext)")
            number += 1
        }
        return url
    }
}

/// A popup window a page opened, such as a sign-in.
private final class BrowserPopup {
    let window: NSWindow
    let webView: WKWebView
    private var observation: NSKeyValueObservation?

    init(configuration: WKWebViewConfiguration, size: CGSize, delegate: BrowserDelegate) {
        webView = WKWebView(frame: CGRect(origin: .zero, size: size), configuration: configuration)
        webView.uiDelegate = delegate
        window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = webView
        observation = webView.observe(\.title) { [weak window] view, _ in
            MainActor.assumeIsolated { window?.title = view.title ?? "" }
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
    }
}

/// Follows the tab's loads and answers what its pages ask of the window.
private final class BrowserDelegate: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    weak var browser: AgentBrowser?
    private var downloads: [ObjectIdentifier: (url: String, file: URL?)] = [:]

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        record(error, in: webView)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        record(error, in: webView)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        browser?.pageStarted()
    }

    private func record(_ error: any Error, in webView: WKWebView) {
        // A navigation replaced by another isn't a failure, nor is a page that became a download.
        let code = (error as NSError).code
        guard webView === browser?.webView, code != NSURLErrorCancelled, code != 102 else { return }
        browser?.loadError = error
        browser?.log("error", "Couldn't load the page: \(error.localizedDescription)")
    }

    /// Notes the page's own status, and saves what it can't show as a download.
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse) async -> WKNavigationResponsePolicy {
        if response.isForMainFrame, let http = response.response as? HTTPURLResponse, let url = http.url {
            browser?.record(AgentBrowser.NetworkEntry(
                id: "doc-\(UUID().uuidString)", method: "GET", url: url.absoluteString, kind: "document", status: http.statusCode,
                type: http.value(forHTTPHeaderField: "Content-Type") ?? ""))
        }
        return response.canShowMIMEType ? .allow : .download
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
        action.shouldPerformDownload ? .download : .allow
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        download.delegate = self
        downloads[ObjectIdentifier(download)] = (navigationResponse.response.url?.absoluteString ?? "", nil)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
        downloads[ObjectIdentifier(download)] = (navigationAction.request.url?.absoluteString ?? "", nil)
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String) async -> URL? {
        guard let browser else { return nil }
        let file = browser.destination(for: suggestedFilename)
        downloads[ObjectIdentifier(download)]?.file = file
        return file
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let entry = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        var record = AgentBrowser.NetworkEntry(id: "dl-\(UUID().uuidString)", method: "GET", url: entry.url, kind: "download", status: 200)
        record.savedTo = entry.file?.path(percentEncoded: false)
        browser?.record(record)
    }

    func download(_ download: WKDownload, didFailWithError error: any Error, resumeData: Data?) {
        guard let entry = downloads.removeValue(forKey: ObjectIdentifier(download)) else { return }
        browser?.record(AgentBrowser.NetworkEntry(id: "dl-\(UUID().uuidString)", method: "GET", url: entry.url, kind: "download", status: 0,
                                                  error: error.localizedDescription))
    }

    /// A sized popup, as a sign-in opens, gets its own window; links and
    /// plain new windows open in the tab, as the browser has no others.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let browser else { return nil }
        if windowFeatures.width == nil, windowFeatures.height == nil {
            if action.request.url != nil { webView.load(action.request) }
            return nil
        }
        return browser.openPopup(configuration: configuration, features: windowFeatures)
    }

    func webViewDidClose(_ webView: WKWebView) {
        browser?.closePopup(webView)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async {
        _ = await browser?.dialog("alert", message: message)
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo) async -> Bool {
        await browser?.dialog("confirm", message: message) != nil
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo) async -> String? {
        await browser?.dialog("prompt", message: prompt, defaultText: defaultText)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo) async -> [URL]? {
        await browser?.chooseFiles(parameters)
    }
}

private final class MessageHandler: NSObject, WKScriptMessageHandler {
    let receive: (String, [String: Any]) -> Void

    init(receive: @escaping (String, [String: Any]) -> Void) {
        self.receive = receive
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        receive(message.name, body)
    }
}

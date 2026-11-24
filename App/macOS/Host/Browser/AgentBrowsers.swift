import Observation

/// The browser each chat on this Mac has opened, by task ID, until the chat
/// is settled or deleted. Each holds a web page process, so none starts
/// before its agent opens a page.
@MainActor
@Observable
final class AgentBrowsers {
    private(set) var browsers: [String: AgentBrowser] = [:]
    /// A chat's browser opened or closed, by task ID, for the window to show or forget it.
    @ObservationIgnored var onOpen: ((String) -> Void)?
    @ObservationIgnored var onClose: ((String) -> Void)?

    func browser(for taskID: String) -> AgentBrowser? {
        browsers[taskID]
    }

    /// The chat's browser, opening one when it has none.
    func browserOpening(for taskID: String) -> AgentBrowser {
        if let browser = browsers[taskID] { return browser }
        let browser = AgentBrowser()
        browsers[taskID] = browser
        onOpen?(taskID)
        return browser
    }

    func close(_ taskID: String) {
        guard let browser = browsers.removeValue(forKey: taskID) else { return }
        browser.close()
        onClose?(taskID)
    }
}

import Observation

/// What each chat's inspector shows in front, for the window's lifetime: the
/// page it has open, its agent's browser, or the project's tools. Each chat
/// keeps its own, so coming back to a chat shows what it showed.
@MainActor
@Observable
final class InspectorPages {
    enum Front {
        case page
        case browser
    }

    private var pages: [TaskRef: ChatPageBlock] = [:]
    /// What's in front of the project's tools, for chats showing something else.
    private var fronts: [TaskRef: Front] = [:]
    /// The newest page each chat had when last seen, by key; nil when it had none.
    @ObservationIgnored private var newestPageKeys: [TaskRef: String?] = [:]

    /// The page open for the chat, in front or a tab away.
    func page(for task: TaskRef) -> ChatPageBlock? {
        pages[task]
    }

    /// The page the inspector shows for the chat; nil while something else is in front.
    func frontPage(for task: TaskRef) -> ChatPageBlock? {
        fronts[task] == .page ? pages[task] : nil
    }

    func showsBrowser(for task: TaskRef) -> Bool {
        fronts[task] == .browser
    }

    func show(_ page: ChatPageBlock, for task: TaskRef) {
        pages[task] = page
        fronts[task] = .page
    }

    /// Brings the chat's open page back in front.
    func bringToFront(for task: TaskRef) {
        if pages[task] != nil { fronts[task] = .page }
    }

    func showBrowser(for task: TaskRef) {
        fronts[task] = .browser
    }

    /// The chat's browser closed: its page, if it has one, comes back in front.
    func browserClosed(for task: TaskRef) {
        guard fronts[task] == .browser else { return }
        fronts[task] = pages[task] == nil ? nil : .page
    }

    /// Shows the project's tools, keeping the page and browser a tab away.
    func showTools(for task: TaskRef) {
        fronts[task] = nil
    }

    /// Notes the page a chat's newest reply ends with, and says whether an
    /// agent just showed it. The first time a chat is seen, its pages are
    /// older than that, so none of them is new.
    func noteNewestPage(_ page: ChatPageBlock?, in task: TaskRef) -> Bool {
        let key = page?.page.key
        guard let known = newestPageKeys.updateValue(key, forKey: task) else { return false }
        return key != nil && key != known
    }
}

extension AppModel {
    /// Shows a page in the inspector beside its chat.
    func showPage(_ page: ChatPageBlock, for task: TaskRef) {
        inspectorPages.show(page, for: task)
        showingInspector = true
    }

    /// Opens the inspector on one of a project's tools, the selected one's
    /// unless another is given, in front of the selected chat's page or browser.
    func showInspector(_ tab: InspectorTab, in project: Project? = nil) {
        showingInspector = true
        (project ?? selectedProject)?.selectedTab = tab
        if let task = selectedTask { inspectorPages.showTools(for: task.id) }
    }

    /// The browser a chat on this Mac has open; chats on other hosts have none here.
    func browser(for task: HostTask) -> AgentBrowser? {
        task.host.isLocal ? browsers.browser(for: task.task.id) : nil
    }

    /// Brings a chat's new browser to the front of its inspector, opening the
    /// inspector when the chat is on screen.
    func showBrowser(for taskID: String) {
        guard let hostID = localHost?.id else { return }
        let task = TaskRef(hostID: hostID, taskID: taskID)
        inspectorPages.showBrowser(for: task)
        if selection == task { showingInspector = true }
    }

    func forgetBrowser(of taskID: String) {
        guard let hostID = localHost?.id else { return }
        inspectorPages.browserClosed(for: TaskRef(hostID: hostID, taskID: taskID))
    }
}

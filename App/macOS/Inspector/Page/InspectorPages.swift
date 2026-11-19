import AtriumClient
import AtriumProtocol
import Observation

/// The page each chat has open in the inspector, for the window's lifetime.
/// Each chat keeps its own, so coming back to a chat shows what it showed.
@MainActor
@Observable
final class InspectorPages {
    private var pages: [TaskRef: ChatPageBlock] = [:]
    /// Chats with a page open whose inspector shows the project's tools instead.
    private var showingTools: Set<TaskRef> = []
    /// The newest page each chat had when last seen, by key; nil when it had none.
    @ObservationIgnored private var newestPageKeys: [TaskRef: String?] = [:]

    /// The page open for the chat, in front or a tab away.
    func page(for task: TaskRef) -> ChatPageBlock? {
        pages[task]
    }

    /// The page the inspector shows for the chat; nil while its tools are in front.
    func frontPage(for task: TaskRef) -> ChatPageBlock? {
        showingTools.contains(task) ? nil : pages[task]
    }

    func show(_ page: ChatPageBlock, for task: TaskRef) {
        pages[task] = page
        showingTools.remove(task)
    }

    /// Brings the chat's open page back in front of the project's tools.
    func bringToFront(for task: TaskRef) {
        showingTools.remove(task)
    }

    /// Shows the project's tools, keeping the page a tab away.
    func showTools(for task: TaskRef) {
        if pages[task] != nil { showingTools.insert(task) }
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
    /// unless another is given, in front of the selected chat's page.
    func showInspector(_ tab: InspectorTab, in project: Project? = nil) {
        showingInspector = true
        (project ?? selectedProject)?.selectedTab = tab
        if let task = selectedTask { inspectorPages.showTools(for: task.id) }
    }
}

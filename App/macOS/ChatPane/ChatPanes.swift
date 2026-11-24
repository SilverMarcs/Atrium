import Foundation
import Observation

/// One thing the pane beside a chat shows.
enum PaneItem: Hashable {
    /// The chat's browser, which its agent drives.
    case browser
    /// A file of the chat's project.
    case file(URL)
    /// A change to one of the project's files.
    case diff(GitDiffReference)
}

/// What each chat's pane shows beside it, for the window's lifetime: one
/// item in front with the ones before and after it, like a browser's
/// history, and whether the pane is open. Each chat keeps its own, so coming
/// back to a chat shows what it showed.
@MainActor
@Observable
final class ChatPanes {
    private struct Pane {
        var back: [PaneItem] = []
        var current: PaneItem?
        var forward: [PaneItem] = []
        var isClosed = false
    }

    private var panes: [TaskRef: Pane] = [:]
    /// While the pane's column slides open or shut, so it shows its content
    /// only once it has room for it.
    var isColumnMoving = false

    /// What the chat's pane shows, open or closed.
    func current(for task: TaskRef) -> PaneItem? {
        panes[task]?.current
    }

    func isOpen(for task: TaskRef) -> Bool {
        guard let pane = panes[task] else { return false }
        return pane.current != nil && !pane.isClosed
    }

    func canGoBack(for task: TaskRef) -> Bool { panes[task]?.back.isEmpty == false }
    func canGoForward(for task: TaskRef) -> Bool { panes[task]?.forward.isEmpty == false }

    /// Opens the pane on an item, after what it showed.
    func open(_ item: PaneItem, for task: TaskRef) {
        var pane = panes[task] ?? Pane()
        if pane.current != item {
            if let current = pane.current { pane.back.append(current) }
            pane.back.removeAll { $0 == item }
            pane.forward.removeAll()
            pane.current = item
        }
        pane.isClosed = false
        panes[task] = pane
    }

    func goBack(for task: TaskRef) {
        guard var pane = panes[task], let previous = pane.back.popLast() else { return }
        if let current = pane.current { pane.forward.append(current) }
        pane.current = previous
        pane.isClosed = false
        panes[task] = pane
    }

    func goForward(for task: TaskRef) {
        guard var pane = panes[task], let next = pane.forward.popLast() else { return }
        if let current = pane.current { pane.back.append(current) }
        pane.current = next
        pane.isClosed = false
        panes[task] = pane
    }

    /// Opens the chat's pane on what it last showed, or closes it.
    func toggle(for task: TaskRef) {
        _ = setOpen(!isOpen(for: task), for: task)
    }

    /// Opens or closes the chat's pane, keeping what it shows; says whether
    /// it could, since a pane with nothing to show stays closed.
    func setOpen(_ open: Bool, for task: TaskRef) -> Bool {
        guard panes[task]?.current != nil else { return !open }
        panes[task]?.isClosed = !open
        return true
    }

    /// The chat's browser closed: it leaves the chat's history, and the pane
    /// goes back to what it showed before.
    func browserClosed(for task: TaskRef) {
        guard var pane = panes[task] else { return }
        pane.back.removeAll { $0 == .browser }
        pane.forward.removeAll { $0 == .browser }
        if pane.current == .browser { pane.current = pane.back.popLast() }
        panes[task] = pane
    }
}

extension AppModel {
    /// Shows a file or diff of the selected chat's project in the pane beside it.
    func showInPane(_ content: EditorPanelContent) {
        guard let task = selection else { return }
        switch content {
        case .file(let url): chatPanes.open(.file(url), for: task)
        case .diff(let reference): chatPanes.open(.diff(reference), for: task)
        }
    }

    /// The project a task runs in, if it has one.
    func project(for task: HostTask) -> Project? {
        task.task.workspaceID.flatMap { project(WorkspaceRef(hostID: task.host.id, workspaceID: $0)) }
    }

    /// Opens the inspector on one of a project's tools, the selected one's
    /// unless another is given.
    func showInspector(_ tab: InspectorTab, in project: Project? = nil) {
        showingInspector = true
        (project ?? selectedProject)?.selectedTab = tab
    }

    /// The browser a chat on this Mac has open; chats on other hosts have none here.
    func browser(for task: HostTask) -> AgentBrowser? {
        task.host.isLocal ? browsers.browser(for: task.task.id) : nil
    }

    /// Opens a chat's new browser in its pane.
    func showBrowser(for taskID: String) {
        guard let hostID = localHost?.id else { return }
        chatPanes.open(.browser, for: TaskRef(hostID: hostID, taskID: taskID))
    }

    func forgetBrowser(of taskID: String) {
        guard let hostID = localHost?.id else { return }
        chatPanes.browserClosed(for: TaskRef(hostID: hostID, taskID: taskID))
    }
}

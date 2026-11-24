import Observation

/// What the window keeps for chats' bottom sheets: the sheets of chats
/// without a project, which only have pages to show, and the newest page each
/// chat had, so a page an agent just showed opens on its own.
@MainActor
@Observable
final class BottomSheets {
    private var panels: [TaskRef: EditorPanel] = [:]
    /// The newest page each chat had when last seen, by key; nil when it had none.
    @ObservationIgnored private var newestPageKeys: [TaskRef: String?] = [:]

    /// The sheet of a chat without a project, once it has shown a page.
    func panel(for task: TaskRef) -> EditorPanel? {
        panels[task]
    }

    /// The sheet a chat without a project shows a page in.
    func openPanel(for task: TaskRef) -> EditorPanel {
        if let panel = panels[task] { return panel }
        let panel = EditorPanel()
        panels[task] = panel
        return panel
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
    /// The project a task works in, with its inspector and editor.
    func project(for item: HostTask) -> Project? {
        item.task.workspaceID.flatMap { project(WorkspaceRef(hostID: item.host.id, workspaceID: $0)) }
    }

    /// The sheet under a chat: its project's, or its own once a chat
    /// without a project has shown a page, as it has nothing else to show.
    func sheet(for item: HostTask) -> EditorPanel? {
        project(for: item)?.editor ?? bottomSheets.panel(for: item.id)
    }

    /// Shows a page in the sheet under its chat.
    func showPage(_ page: ChatPageBlock, for task: TaskRef) {
        guard let item = hosts.task(task) else { return }
        (project(for: item)?.editor ?? bottomSheets.openPanel(for: task)).openPage(page, in: task)
    }

    /// Opens or closes the sheet under the chat on screen.
    func toggleBottomSheet() {
        selectedTask.flatMap(sheet(for:))?.toggle()
    }

    /// Opens the inspector on one of a project's tools, the selected one's
    /// unless another is given.
    func showInspector(_ tab: InspectorTab, in project: Project? = nil) {
        showingInspector = true
        (project ?? selectedProject)?.selectedTab = tab
    }
}

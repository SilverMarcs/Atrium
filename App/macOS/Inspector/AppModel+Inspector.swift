import SwiftUI

struct ChatInspectorState: Codable, Equatable {
    private static let defaultsKey = "chatInspectorStates"

    var isPresented = true
    var tab: InspectorTab = .files

    static func loadSaved(from defaults: UserDefaults = .standard) -> [TaskRef: Self] {
        guard let data = defaults.data(forKey: defaultsKey) else { return [:] }
        return (try? PropertyListDecoder().decode([TaskRef: Self].self, from: data)) ?? [:]
    }

    static func save(_ states: [TaskRef: Self], to defaults: UserDefaults = .standard) {
        let conversations = states.filter { !TaskDraft.isDraftID($0.key.taskID) }
        if let data = try? PropertyListEncoder().encode(conversations) {
            defaults.set(data, forKey: defaultsKey)
        }
    }
}

extension AppModel {
    private var inspectorChat: TaskRef? { selectedTask?.id ?? selection }

    var inspectorState: ChatInspectorState {
        get {
            guard let chat = inspectorChat else { return inspectorWithoutChat }
            return inspectorByChat[chat] ?? ChatInspectorState()
        }
        set {
            guard newValue != inspectorState else { return }
            guard let chat = inspectorChat else {
                inspectorWithoutChat = newValue
                return
            }
            inspectorByChat[chat] = newValue
            if !TaskDraft.isDraftID(chat.taskID) { ChatInspectorState.save(inspectorByChat) }
        }
    }

    var showingInspector: Bool {
        get { inspectorState.isPresented }
        set { inspectorState.isPresented = newValue }
    }

    /// Carries the presentation across the new chat's first prompt.
    func transferInspector(from draft: TaskRef, to task: TaskRef) {
        if let state = inspectorByChat.removeValue(forKey: draft), inspectorByChat[task] == nil {
            inspectorByChat[task] = state
            ChatInspectorState.save(inspectorByChat)
        }
        InspectorWidthMemory.transfer(from: draft, to: task)
    }

    /// Shows a tool in the current chat.
    func showInspector(_ tab: InspectorTab, in project: Project? = nil) {
        if let project, project !== selectedProject { return }
        inspectorState = ChatInspectorState(isPresented: true, tab: tab)
    }

    /// The tab the inspector shows for a project: Files in place of the
    /// browser or simulator for a chat on another host.
    func inspectorTab(for project: Project) -> InspectorTab {
        let tab = inspectorState.tab
        return tab.isOnThisMac && !project.isLocal ? .files : tab
    }

    /// Opens a tab that shows something of a chat's, such as its browser or
    /// simulator, when that chat is on screen.
    func showInspector(_ tab: InspectorTab, for taskID: String) {
        guard let hostID = localHost?.id, inspectorChat == TaskRef(hostID: hostID, taskID: taskID) else { return }
        showInspector(tab)
    }

    /// Opens a web page, or an HTML file on this Mac, in the chat's browser
    /// and brings it to the front: its window, or the inspector's tab. Nil
    /// for a chat that can't show one there: one on another host, or with no
    /// project and so no inspector.
    func browse(in item: HostTask?, openWindow: OpenWindowAction) -> ((URL) -> Void)? {
        guard let item, item.host.isLocal, item.task.workspaceID != nil else { return nil }
        let taskID = item.task.id
        return { [weak self] url in
            guard let self else { return }
            let browser = browsers.browserOpening(for: taskID)
            if browser.isInWindow {
                openWindow(value: BrowserWindowItem(taskID: taskID))
            } else {
                showInspector(.browser, for: taskID)
            }
            Task { try? await browser.open(url) }
        }
    }
}

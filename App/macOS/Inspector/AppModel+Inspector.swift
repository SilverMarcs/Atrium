import SwiftUI

extension AppModel {
    /// Opens the inspector on one of a project's tools, the selected one's
    /// unless another is given.
    func showInspector(_ tab: InspectorTab, in project: Project? = nil) {
        showingInspector = true
        (project ?? selectedProject)?.selectedTab = tab
    }

    /// Opens a tab that shows something of a chat's, such as its browser or
    /// simulator, when that chat is on screen.
    func showInspector(_ tab: InspectorTab, for taskID: String) {
        guard let hostID = localHost?.id, selection == TaskRef(hostID: hostID, taskID: taskID) else { return }
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

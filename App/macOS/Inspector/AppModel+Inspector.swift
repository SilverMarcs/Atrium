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
}

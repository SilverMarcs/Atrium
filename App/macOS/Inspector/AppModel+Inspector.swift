import SwiftUI

extension AppModel {
    /// Opens the inspector on one of a project's tools, the selected one's
    /// unless another is given.
    func showInspector(_ tab: InspectorTab, in project: Project? = nil) {
        showingInspector = true
        (project ?? selectedProject)?.selectedTab = tab
    }

    /// A chat's new browser shows in the inspector's Browser tab, opened when
    /// the chat is on screen.
    func showBrowser(for taskID: String) {
        guard let hostID = localHost?.id, selection == TaskRef(hostID: hostID, taskID: taskID) else { return }
        showInspector(.browser)
    }
}

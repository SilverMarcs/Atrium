import SwiftUI

@Observable
final class AppState {
    var selectedChat: Chat? {
        didSet {
            oldValue?.hasNotification = false
            selectedChat?.hasNotification = false
        }
    }

    // Sidebar expansion state
    var expandedWorkspaceIDs: Set<String> = []

    // Drives NavigationSplitView column visibility so we can toggle the
    // sidebar programmatically (e.g. when the bottom editor panel expands).
    var sidebarVisibility: NavigationSplitViewVisibility = .automatic

    // Inspector state
    var showingInspector = true

    // Whether archived workspaces are temporarily revealed in the sidebar.
    var showArchivedWorkspaces = false
}

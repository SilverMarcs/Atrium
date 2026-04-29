import SwiftUI

/// Controls what happens to the sidebar and inspector when the bottom
/// editor panel is expanded.
enum EditorPanelSidebarBehavior: String, CaseIterable, Identifiable {
    case `default`
    case hideSidebar
    case hideInspector
    case hideBoth

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .default: "Default"
        case .hideSidebar: "Hide sidebar"
        case .hideInspector: "Hide inspector"
        case .hideBoth: "Hide both"
        }
    }

    var hidesSidebar: Bool {
        self == .hideSidebar || self == .hideBoth
    }

    var hidesInspector: Bool {
        self == .hideInspector || self == .hideBoth
    }
}

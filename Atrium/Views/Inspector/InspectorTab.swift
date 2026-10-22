import Foundation

enum InspectorTab: Int, CaseIterable, Identifiable {
    case files
    case git
    case search
    case commands

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .files: "Files"
        case .search: "Search"
        case .git: "Git"
        case .commands: "Commands"
        }
    }

    var icon: String {
        switch self {
        case .files: "folder"
        case .search: "magnifyingglass"
        case .git: "point.topleft.down.curvedto.point.bottomright.up"
        case .commands: "terminal"
        }
    }

    var selectedIcon: String {
        switch self {
        case .files: "folder.fill"
        case .search: "magnifyingglass.circle.fill"
        case .git: "point.topleft.down.curvedto.point.bottomright.up.fill"
        case .commands: "terminal.fill"
        }
    }
}

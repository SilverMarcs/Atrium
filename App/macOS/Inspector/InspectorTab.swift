import Foundation

enum InspectorTab: Int, CaseIterable, Identifiable {
    case files
    case git
    case search
    case commands
    case browser
    case simulator

    var id: Int { rawValue }

    /// The tabs the inspector's picker offers: the browser takes Search's
    /// place, which still works but stays out of the picker and the menus for now.
    static let shown: [InspectorTab] = [.files, .git, .browser, .simulator, .commands]

    #if DEBUG
    init?(debugName: String) {
        guard let tab = Self.allCases.first(where: { $0.label.lowercased() == debugName }) else { return nil }
        self = tab
    }
    #endif

    var label: String {
        switch self {
        case .files: "Files"
        case .search: "Search"
        case .git: "Git"
        case .commands: "Commands"
        case .browser: "Browser"
        case .simulator: "Simulator"
        }
    }

    var icon: String {
        switch self {
        case .files: "folder"
        case .search: "magnifyingglass"
        case .git: "point.topleft.down.curvedto.point.bottomright.up"
        case .commands: "terminal"
        case .browser: "globe"
        case .simulator: "iphone"
        }
    }
}

/// A selection value paired with the identity of the per-project state that
/// owns it. Inspector views keep a stable SwiftUI identity across project
/// switches (re-keying them with .id flickers the toolbar), so a plain
/// `.onChange(of: model.selectedID)` also fires when the whole model is swapped
/// for another project's. Handlers compare `owner` to tell an explicit
/// selection change (same owner → open the bottom panel) from a project switch
/// (different owner → leave the panel as that project left it).
struct InspectorSelection<Value: Equatable>: Equatable {
    let owner: ObjectIdentifier
    let selection: Value

    init(_ owner: AnyObject, _ selection: Value) {
        self.owner = ObjectIdentifier(owner)
        self.selection = selection
    }
}

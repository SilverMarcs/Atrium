import Foundation

/// How a diff is laid out: removed and added lines in one column, or the old
/// file beside the new one.
enum DiffLayout: String, CaseIterable, Identifiable {
    case unified
    case sideBySide

    /// The layout diff viewers open with, set in Settings.
    static let key = "diffLayout"

    var id: Self { self }

    var title: String {
        switch self {
        case .unified: "Unified"
        case .sideBySide: "Side by Side"
        }
    }

    var toggled: DiffLayout {
        self == .unified ? .sideBySide : .unified
    }
}

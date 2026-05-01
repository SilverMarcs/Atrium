import Foundation

enum QuickPanelHeight: Equatable {
    case collapsed
    case expanded

    var value: CGFloat {
        switch self {
        case .collapsed: return 60
        case .expanded: return 500
        }
    }
}

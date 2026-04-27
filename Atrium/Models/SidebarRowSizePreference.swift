import SwiftUI

enum SidebarRowSizePreference: String, CaseIterable, Identifiable {
    case small
    case medium
    case large

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .small: "Small"
        case .medium: "Medium"
        case .large: "Large"
        }
    }

    var sidebarRowSize: SidebarRowSize {
        switch self {
        case .small: .small
        case .medium: .medium
        case .large: .large
        }
    }
}

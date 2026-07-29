import SwiftUI

enum AppUIScale: String, CaseIterable {
    static let key = "appUIScale"

    case small
    case medium
    case standard
    case large
    case extraLarge

    var dynamicTypeSize: DynamicTypeSize {
        switch self {
        case .small: .small
        case .medium: .medium
        case .standard: .large
        case .large: .xLarge
        case .extraLarge: .xxLarge
        }
    }

    var increased: Self {
        stepped(by: 1)
    }

    var decreased: Self {
        stepped(by: -1)
    }

    private func stepped(by offset: Int) -> Self {
        let scales = Self.allCases
        let currentIndex = scales.firstIndex(of: self) ?? scales.startIndex
        let nextIndex = min(
            max(currentIndex + offset, scales.startIndex),
            scales.index(before: scales.endIndex)
        )
        return scales[nextIndex]
    }
}

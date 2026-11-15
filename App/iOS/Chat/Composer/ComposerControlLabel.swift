import SwiftUI

/// Matching touch targets for the expanded composer's icon controls.
struct ComposerControlLabel<Content: View>: View {
    var isWarning = false
    @ViewBuilder let content: Content

    var body: some View {
        content
            .font(.title2)
            // Bound only the icons to their toolbar cells. Picker text
            // retains the user's full Dynamic Type size.
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .foregroundStyle(isWarning ? .orange : .secondary)
            .frame(width: ComposerBarLayout.menuControlSize, height: ComposerBarLayout.menuControlSize)
            .contentShape(.circle)
    }
}

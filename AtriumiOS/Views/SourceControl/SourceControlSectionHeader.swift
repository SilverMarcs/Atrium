import SwiftUI

/// Header for a Section in the source control list. Sections are used (not
/// disclosure groups), so the per-section group action menu lives here on
/// the trailing edge instead of in a section's context menu.
struct SourceControlSectionHeader<Menu: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var menuItems: () -> Menu

    var body: some View {
        SwiftUI.Menu {
            menuItems()
        } label: {
            Label(title, systemImage: systemImage)
        }
        .foregroundStyle(.secondary)
        .menuStyle(.borderlessButton)
    }
}

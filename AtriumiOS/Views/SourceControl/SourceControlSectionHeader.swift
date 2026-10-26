import SwiftUI

/// Header for a section in the source control list: tapping the title folds the
/// section, and the trailing menu holds actions for every file in it.
struct SourceControlSectionHeader<Menu: View>: View {
    let title: String
    let systemImage: String
    @Binding var isExpanded: Bool
    @ViewBuilder var menuItems: () -> Menu

    var body: some View {
        HStack {
            Button {
                withAnimation { isExpanded.toggle() }
            } label: {
                HStack {
                    Label(title, systemImage: systemImage)
                    Image(systemName: "chevron.right")
                        .imageScale(.small)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")

            Spacer()

            SwiftUI.Menu {
                menuItems()
            } label: {
                Label("Actions", systemImage: "ellipsis")
                    .labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
        }
        .foregroundStyle(.secondary)
    }
}

import SwiftUI

struct AssistantLabel: View {
    @Environment(\.colorScheme) var colorScheme
    let provider: AgentProvider
    var isConnected: Bool = true

    var body: some View {
        Label {
            Text(provider.rawValue)
                .font(.subheadline)
                .bold()
                .foregroundStyle(.secondary)
                .foregroundStyle(provider.color)
                .brightness(colorScheme == .dark ? 1.1 : -0.5)
        } icon: {
            Image(provider.imageName)
                .imageScale(.large)
                .foregroundStyle(provider.color.gradient)
        }
        .labelIconToTitleSpacing(5)
        .saturation(isConnected ? 1 : 0)
        .animation(.default, value: isConnected)
    }
}

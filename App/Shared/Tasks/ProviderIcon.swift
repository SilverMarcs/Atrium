import SwiftUI

/// An agent's symbol in its color, or grayed out when its task has no live session.
struct ProviderIcon: View {
    let provider: AgentProvider
    var isLive = true

    var body: some View {
        Image(provider.symbolName)
            .foregroundStyle(isLive ? provider.color : .secondary)
            .accessibilityLabel(provider.name)
    }
}

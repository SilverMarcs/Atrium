import AtriumProtocol
import SwiftUI

/// Centers the selected provider in the space above the new-chat controls.
struct NewChatPlaceholder: View {
    let provider: AgentProvider

    var body: some View {
        Image(provider.symbolName)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 80, maxHeight: 80)
            .foregroundStyle(.tertiary)
            .contentTransition(.symbolEffect(.replace))
            .accessibilityLabel(provider.name)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

import AtriumClient
import AtriumProtocol
import SwiftUI

struct NewChatAgentPicker: View {
    let host: HostClient
    let draft: TaskDraft

    var body: some View {
        if !host.availableProviders.isEmpty {
            Menu {
                Picker("Agent", selection: Binding(
                    get: { draft.provider },
                    set: { host.setProvider($0, ofDraft: draft.id) }
                ).animation()) {
                    ForEach(host.availableProviders) { provider in
                        Label {
                            Text(provider.name)
                        } icon: {
                            Image(provider.symbolName)
                        }
                        .tag(provider)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                NewChatPickerLabel(title: draft.provider.name) {
                    Image(draft.provider.symbolName)
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(draft.provider.color)
                }
            }
            .disabled(host.availableProviders.count < 2)
            .accessibilityLabel("Agent")
            .accessibilityValue(draft.provider.name)
        }
    }
}

import AtriumClient
import AtriumProtocol
import SwiftUI

struct NewChatAgentPicker: View {
    let host: HostClient
    let draft: TaskDraft

    var body: some View {
        if !host.enabledProviders.isEmpty {
            Menu {
                Picker("Agent", selection: Binding(
                    get: { draft.provider },
                    set: { host.setProvider($0, ofDraft: draft.id) }
                ).animation()) {
                    ForEach(host.enabledProviders) { provider in
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
            .disabled(host.enabledProviders.count < 2)
            .accessibilityLabel("Agent")
            .accessibilityValue(draft.provider.name)
        }
    }
}

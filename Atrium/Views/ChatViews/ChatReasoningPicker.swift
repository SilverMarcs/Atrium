import SwiftUI

struct ChatReasoningPicker: View {
    @Bindable var chat: Chat
    private let symbols = ["gauge.with.dots.needle.bottom.0percent", "gauge.with.dots.needle.bottom.50percent", "gauge.with.dots.needle.bottom.100percent"]

    private var levels: [ReasoningLevel] {
        let models = chat.session.models.isEmpty ? ModelCatalog.shared.models(for: chat.provider) : chat.session.models
        return Array((models.first { $0.rawValue == chat.model }?.reasoningLevels ?? []).prefix(symbols.count))
    }

    var body: some View {
        if !levels.isEmpty {
            Picker("Reasoning", selection: Binding(get: { chat.reasoningLevel }, set: { chat.selectReasoningLevel($0) })) {
                ForEach(levels.enumerated(), id: \.element.id) { index, level in
                    Label(level.name, systemImage: symbols[index])
                        .labelStyle(.iconOnly)
                        .tag(level.id)
                        .help("\(level.name): \(level.description)")
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .help(levels.first { $0.id == chat.reasoningLevel }?.description ?? "Reasoning")
            .disabled(chat.session.isConnecting)
        }
    }
}

import SwiftUI

struct ChatModelPicker: View {
    @Bindable var chat: Chat

    private var models: [AgentModel] {
        chat.session.models.isEmpty ? ModelCatalog.shared.models(for: chat.provider) : chat.session.models
    }

    private var selectedModelName: String {
        models.first { $0.rawValue == chat.model }?.name ?? (chat.model.isEmpty ? "Model" : chat.model)
    }

    var body: some View {
        Picker(selection: Binding(get: { chat.model }, set: { chat.selectModel($0) })) {
            if models.isEmpty { Text("Loading models…").tag("") }
            ForEach(models) { model in
                Label(model.name, image: chat.provider.imageName)
                    .labelStyle(.titleAndIcon)
                    .tag(model.rawValue)
            }
        } label: {
            Label(selectedModelName, image: chat.provider.imageName)
                .labelStyle(.titleAndIcon)
        }
        .pickerStyle(.menu)
        .menuOrder(.fixed)
        .frame(maxWidth: 187.5)
        .disabled(models.isEmpty || chat.session.isConnecting)
    }
}

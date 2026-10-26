import SwiftUI

/// The model picker's items: fast mode, when the task's model offers it, then
/// each model its provider lists, opening that model's reasoning efforts.
/// Choosing an effort, or a model without any, switches the task's next turns
/// to it.
struct TaskModelMenuItems: View {
    @Environment(CompanionClient.self) private var client
    let task: WireTask
    let models: [AgentModel]

    private var currentModel: AgentModel? { models.model(running: task.model) }
    private var isFastMode: Bool { task.isFastMode == true }

    var body: some View {
        Group {
            if currentModel?.supportsFastMode == true {
                // A filled bolt shows fast mode is on, in place of a checkmark.
                Button("Fast Mode", systemImage: isFastMode ? "bolt.fill" : "bolt") {
                    client.send(.task(id: task.id, action: .setFastMode(!isFastMode)))
                }
                .accessibilityValue(isFastMode ? "On" : "Off")
            }

            Section("Model") {
                ForEach(models) { model in
                    if model.reasoningEfforts.isEmpty {
                        Button {
                            guard model != currentModel else { return }
                            select(model, reasoningEffort: nil)
                        } label: {
                            Text(model.name)
                        }
                    } else {
                        Menu {
                            Picker(model.name, selection: Binding(
                                get: { model == currentModel ? task.reasoningEffort ?? "" : "" },
                                set: { select(model, reasoningEffort: $0) }
                            )) {
                                ForEach(model.reasoningEfforts, id: \.self) { effort in
                                    Text(AgentModel.effortName(effort)).tag(effort)
                                }
                            }
                            .pickerStyle(.inline)
                        } label: {
                            Text(model.name)
                        }
                    }
                }
            }
        }
        .disabled(!task.actions.contains(.selectModel))
    }

    private func select(_ model: AgentModel, reasoningEffort: String?) {
        client.send(.task(id: task.id, action: .selectModel(id: model.id, reasoningEffort: reasoningEffort)))
    }
}

import AtriumProtocol
import SwiftUI

/// The model picker's items: fast mode, when the task's model offers it, then
/// each model its provider lists, opening that model's reasoning efforts.
/// Choosing an effort, or a model without any, switches the task's next turns
/// to it. The optional header shows context usage once its provider has said.
struct TaskModelMenuItems: View {
  let selection: TaskModelSelection
  let models: [AgentModel]
  let showsContextUsage: Bool
  let perform: (TaskAction) -> Void

  private var currentModel: AgentModel? { models.model(running: selection.model) }
  private var isFastMode: Bool { selection.isFastMode }

  var body: some View {
    Group {
      if currentModel?.supportsFastMode == true {
        // A filled bolt shows fast mode is on, in place of a checkmark.
        Button(isFastMode ? "Disable Fast Mode" : "Enable Fast Mode", systemImage: isFastMode ? "bolt.fill" : "bolt") {
          perform(.setFastMode(!isFastMode))
        }
        .accessibilityValue(isFastMode ? "On" : "Off")
      }

      Section {
        ForEach(models) { model in
          if model.reasoningEfforts.isEmpty {
            Button {
              guard model != currentModel else { return }
              select(model, reasoningEffort: nil)
            } label: {
              TaskModelOptionLabel(title: model.name, isSelected: model == currentModel)
            }
            .accessibilityAddTraits(model == currentModel ? .isSelected : [])
          } else {
            Menu {
              Picker(
                "",
                selection: Binding(
                  get: { model == currentModel ? selection.reasoningEffort ?? "" : "" },
                  set: { select(model, reasoningEffort: $0) }
                )
              ) {
                ForEach(model.reasoningEfforts, id: \.self) { effort in
                  Text(AgentModel.effortName(effort)).tag(effort)
                }
              }
              .labelsHidden()
              .accessibilityLabel("Reasoning effort")
              .pickerStyle(.inline)
            } label: {
              TaskModelOptionLabel(title: model.name, isSelected: model == currentModel)
            }
            .accessibilityAddTraits(model == currentModel ? .isSelected : [])
          }
        }
      } header: {
        if showsContextUsage, let percent = selection.contextUsedPercent {
          Text("\(percent)% context used")
        } else {
          Text("Model")
        }
      }
    }
    .disabled(!selection.canSelectModel)
  }

  private func select(_ model: AgentModel, reasoningEffort: String?) {
    perform(.selectModel(id: model.id, reasoningEffort: reasoningEffort))
  }
}

import AtriumProtocol
import SwiftUI

/// The task's model picker, named for the model and effort it runs with: a
/// submenu of More on iPhone and iPad, and a toolbar button on Mac.
struct TaskModelMenu: View {
  let provider: AgentProvider
  let selection: TaskModelSelection
  let models: [AgentModel]
  let perform: (TaskAction) -> Void
  var showsToolbarLabel = false
  var isNewChatRow = false

  var body: some View {
    let name = models.model(running: selection.model)?.name ?? selection.model ?? "Model"
    let detail = selection.reasoningEffort.map(AgentModel.effortName) ?? ""

    Menu {
      TaskModelMenuItems(selection: selection, models: models, perform: perform)
    } label: {
      if isNewChatRow {
        NewChatPickerLabel(title: [name, detail].filter { !$0.isEmpty }.joined(separator: " · ")) {
          Image(systemName: "cpu")
        }
      } else if showsToolbarLabel {
        Label {
          Text(name)
          Text(detail)
        } icon: {
          Image(provider.symbolName)
        }
      } else {
        Label {
          Text([name, detail].filter { !$0.isEmpty }.joined(separator: " · "))
        } icon: {
          Image(provider.symbolName)
        }
      }
    }
    #if os(macOS)
    .labelStyle(.titleAndIcon)
    #endif
    .accessibilityLabel("Model")
    .accessibilityValue([name, detail].filter { !$0.isEmpty }.joined(separator: " · "))
  }
}

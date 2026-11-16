import AtriumProtocol
import SwiftUI

/// The task's model picker, named for the model and effort it runs with: a
/// menu in the expanded composer or a task toolbar.
struct TaskModelMenu: View {
  let provider: AgentProvider
  let selection: TaskModelSelection
  let models: [AgentModel]
  let perform: (TaskAction) -> Void
  var isComposerRow = false

  private var showsContextUsage: Bool {
    #if os(iOS)
    !isComposerRow
    #else
    true
    #endif
  }

  var body: some View {
    let name = models.model(running: selection.model)?.name ?? selection.model ?? "Model"
    let detail = selection.reasoningEffort.map(AgentModel.effortName) ?? ""

    Menu {
      TaskModelMenuItems(
        selection: selection, models: models, showsContextUsage: showsContextUsage, perform: perform
      )
    } label: {
      if isComposerRow {
        #if os(iOS)
        ComposerControlLabel {
          Label {
            Text("Model")
          } icon: {
            Image(systemName: ComposerReasoningSymbol.name(for: selection.reasoningEffort))
              .symbolRenderingMode(.palette)
              .foregroundStyle(.blue, .secondary)
          }
            .labelStyle(.iconOnly)
            .contentTransition(.symbolEffect(.replace))
        }
        #else
        ComposerMenuLabel {
          Text(name)
          if !detail.isEmpty {
            Text(detail)
              .foregroundStyle(.tertiary)
          }
        }
        #endif
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

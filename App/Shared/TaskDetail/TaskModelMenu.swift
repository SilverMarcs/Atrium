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
  /// The Mac's inline composer shows only the effort gauge, as the iPhone
  /// and iPad composer does.
  var isCompact = false

  var body: some View {
    let name = models.model(running: selection.model)?.name ?? selection.model ?? "Model"
    let detail = selection.reasoningEffort.map(AgentModel.effortName) ?? ""

    Menu {
      TaskModelMenuItems(
        selection: selection, models: models, perform: perform
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
        if isCompact {
          Label {
            Text("Model")
          } icon: {
            Image(systemName: ComposerReasoningSymbol.name(for: selection.reasoningEffort))
              .symbolRenderingMode(.palette)
              .foregroundStyle(.blue, .secondary)
          }
          .labelStyle(.iconOnly)
          .font(.title3)
          .contentTransition(.symbolEffect(.replace))
          .frame(width: ComposerBarLayout.inlineMenuSize, height: ComposerBarLayout.inlineMenuSize)
          .contentShape(.circle)
        } else {
          ComposerMenuLabel {
            Text(name)
            if !detail.isEmpty {
              Text(detail)
                .foregroundStyle(.tertiary)
            }
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

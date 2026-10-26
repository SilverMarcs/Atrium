import SwiftUI

/// The task's model picker, named for the model and effort it runs with: a
/// submenu of the iPhone's More menu, and a toolbar button on iPad.
struct TaskModelMenu: View {
    let task: WireTask
    let models: [AgentModel]

    var body: some View {
        Menu {
            TaskModelMenuItems(task: task, models: models)
        } label: {
            Label(task.modelSummary(using: models) ?? "Model", systemImage: "cpu")
        }
    }
}

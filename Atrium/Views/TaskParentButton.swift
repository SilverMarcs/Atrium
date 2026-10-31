import AtriumClient
import AtriumProtocol
import SwiftUI

/// Returns from a delegated session or subagent to the session that started it.
struct TaskParentButton: View {
    let parent: WireTask
    let hostID: String
    let open: (TaskRef) -> Void

    var body: some View {
        Button("Back to \(parent.title)", systemImage: "chevron.backward") {
            open(TaskRef(hostID: hostID, taskID: parent.id))
        }
        .help("Back to \(parent.title)")
    }
}

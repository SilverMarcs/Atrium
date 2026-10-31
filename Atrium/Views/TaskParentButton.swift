import AtriumClient
import AtriumProtocol
import SwiftUI

/// Returns from a subagent or side chat to the session it belongs to.
struct TaskParentButton: View {
    let parent: WireTask
    let hostID: String
    let open: (TaskRef) -> Void

    var body: some View {
        Button("Back", systemImage: "chevron.backward") {
            open(TaskRef(hostID: hostID, taskID: parent.id))
        }
        .labelStyle(.iconOnly)
        .help("Back to \(parent.title)")
    }
}

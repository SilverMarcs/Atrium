import AtriumClient
import SwiftUI

/// A task's subagents, badged with how many are still working or waiting for an answer.
struct SubagentMenu: View {
    let item: HostTask
    let open: (TaskRef) -> Void

    var body: some View {
        Menu("Subagents", systemImage: "rectangle.stack") {
            SubagentButtons(item: item, open: open)
        }
        // How many are still working, or waiting for an answer.
        .badge(item.workingSubagents)
        #if os(macOS)
        .menuIndicator(.hidden)
        .help("Subagents working for this task")
        #endif
    }
}

import AtriumClient
import SwiftUI

/// A task's delegated sessions and subagents, badged with how many are still working or waiting for an answer.
struct DelegatedTaskMenu: View {
    let item: HostTask
    let open: (TaskRef) -> Void

    var body: some View {
        Menu("Subagents", systemImage: "rectangle.stack") {
            DelegatedTaskButtons(item: item, open: open)
        }
        // How many are still working, or waiting for an answer.
        .badge(item.workingDelegatedTasks)
        #if os(macOS)
        .menuIndicator(.hidden)
        .help("Sessions working for this task")
        #endif
    }
}

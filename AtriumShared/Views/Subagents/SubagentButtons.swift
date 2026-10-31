import AtriumClient
import AtriumProtocol
import SwiftUI

/// Every subagent a task's agent ran, finished or not, as menu items. They
/// aren't listed, so this is where they're opened.
struct SubagentButtons: View {
    let item: HostTask
    let open: (TaskRef) -> Void

    var body: some View {
        ForEach(item.host.tasks?.children(of: item.task.id) ?? []) { child in
            Button {
                open(TaskRef(hostID: item.host.id, taskID: child.id))
            } label: {
                Label {
                    Text(child.title)
                    Text("\(child.provider.name) · \(child.status.rawValue)")
                } icon: {
                    Image(systemName: child.status.systemImage)
                }
            }
        }
        // Mac menus leave out icons unless asked.
        .labelStyle(.titleAndIcon)
    }
}

extension HostTask {
    /// Whether this task's agent ran any subagents.
    var hasSubagents: Bool {
        host.tasks?.tasks.contains { $0.origin?.parentID == task.id } == true
    }

    /// Its subagents still working or waiting for an answer.
    var workingSubagents: Int {
        host.tasks?.children(of: task.id).count(where: \.status.isWorking) ?? 0
    }

    /// The task's status for its progress indicators in its chat and its
    /// list row, which stay up while its subagents work in the background
    /// after its own turn ends.
    var progressStatus: AgentThreadStatus {
        task.status.isWorking || workingSubagents == 0 ? task.status : .processing
    }

    /// The session a subagent works for, when it's listed.
    var parent: WireTask? { host.tasks?.parent(of: task) }

    /// Approvals and questions waiting in the subagents below this task, at any depth.
    var subagentRequests: [AgentInteraction] {
        (host.tasks?.descendants(of: task.id) ?? []).flatMap(\.interactions)
    }
}

import AtriumClient
import AtriumProtocol
import SwiftUI

/// Every session a task delegated work to and every subagent its agent ran,
/// finished or not, as menu items. They aren't listed, so this is where they're opened.
struct DelegatedTaskButtons: View {
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
    /// Whether this task delegated work to any session or ran subagents.
    var hasDelegatedTasks: Bool {
        host.tasks?.tasks.contains { $0.origin?.parentID == task.id } == true
    }

    /// Its delegated sessions and subagents still working or waiting for an answer.
    var workingDelegatedTasks: Int {
        host.tasks?.children(of: task.id).count { $0.status == .processing || $0.status == .waiting } ?? 0
    }

    /// The task's status for its progress indicator, which stays up while
    /// work below it runs after its own turn ends, as Claude's does while its
    /// subagents work in the background.
    var progressStatus: AgentThreadStatus {
        task.status == .processing || task.status == .waiting || workingDelegatedTasks == 0 ? task.status : .processing
    }

    /// The session that delegated this one or ran it as a subagent, when it's listed.
    var parent: WireTask? { host.tasks?.parent(of: task) }

    /// Requests waiting in the work below this task, at any depth: approvals,
    /// and a subagent's questions. A delegated session's questions go to this
    /// task's agent instead.
    var delegatedRequests: [AgentInteraction] {
        (host.tasks?.descendants(of: task.id) ?? []).flatMap { child in
            child.isSubagent ? child.interactions : child.interactions.filter(\.questions.isEmpty)
        }
    }
}

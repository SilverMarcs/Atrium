import AtriumClient
import AtriumProtocol
import SwiftUI

/// Every subagent a task's agent ran, finished or not, as menu items: those
/// still working first, then the rest, each newest first. They aren't listed,
/// so this is where they're opened.
struct SubagentButtons: View {
    let item: HostTask
    let open: (TaskRef) -> Void

    var body: some View {
        let subagents = item.subagents
        let working = subagents.filter(\.status.isWorking)
        let finished = subagents.filter { !$0.status.isWorking }
        Group {
            ForEach(working) { button(for: $0) }
            if !working.isEmpty, !finished.isEmpty {
                Divider()
            }
            ForEach(finished) { button(for: $0) }
        }
        // Mac menus leave out icons unless asked.
        .labelStyle(.titleAndIcon)
    }

    private func button(for subagent: WireTask) -> some View {
        Button {
            open(TaskRef(hostID: item.host.id, taskID: subagent.id))
        } label: {
            Label(subagent.title, systemImage: subagent.status.systemImage)
            // The icon shows its status, so the line under it names who ran it.
            Text([subagent.provider.name, subagent.modelSelection.modelName(using: item.host.models(for: subagent.provider))]
                .compactMap(\.self).joined(separator: " · "))
        }
    }
}

extension HostTask {
    /// The subagents this task's agent ran, newest first.
    var subagents: [WireTask] { host.tasks?.children(of: task.id) ?? [] }

    /// Whether this task's agent ran any subagents.
    var hasSubagents: Bool { !subagents.isEmpty }

    /// The side chat about this task's conversation, while it lasts.
    var sideChat: WireTask? { host.tasks?.sideChat(of: task.id) }

    /// Its subagents still working or waiting for an answer.
    var workingSubagents: Int { subagents.count(where: \.status.isWorking) }

    /// The task's status for its progress indicators in its chat and its
    /// list row, which stay up while its subagents work in the background
    /// after its own turn ends.
    var progressStatus: AgentThreadStatus {
        task.status.isWorking || workingSubagents == 0 ? task.status : .processing
    }

    /// The session a subagent works for, when it's listed.
    var parent: WireTask? { host.tasks?.parent(of: task) }

    /// Approvals and questions waiting on the task, then in the subagents
    /// below it at any depth, which come up with the task's own as those
    /// sessions aren't listed.
    var pendingRequests: [AgentInteraction] {
        task.interactions + (host.tasks?.descendants(of: task.id) ?? []).flatMap(\.interactions)
    }
}

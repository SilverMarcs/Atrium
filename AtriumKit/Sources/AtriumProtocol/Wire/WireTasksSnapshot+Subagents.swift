import Foundation

public nonisolated extension WireTasksSnapshot {
    /// The subagents a task's agent ran, newest first.
    func children(of id: String) -> [WireTask] {
        tasks.filter { $0.origin?.parentID == id }.sorted(by: WireTask.newestFirst)
    }

    /// The session a subagent works for, when that session is listed.
    func parent(of task: WireTask) -> WireTask? {
        guard let id = task.origin?.parentID else { return nil }
        return tasks.first { $0.id == id }
    }

    /// The listed session a task belongs under, following subagents up to
    /// the first session listed on its own, or nil when the task is listed itself.
    func listedAncestor(of task: WireTask) -> WireTask? {
        var visited: Set<String> = [task.id]
        var ancestor = parent(of: task)
        while let current = ancestor, let next = parent(of: current), visited.insert(current.id).inserted {
            ancestor = next
        }
        return ancestor
    }

    /// Every subagent below a task, at any depth.
    func descendants(of id: String) -> [WireTask] {
        var found: [WireTask] = []
        var pending = [id]
        var visited: Set<String> = [id]
        while let next = pending.popLast() {
            for child in children(of: next) where visited.insert(child.id).inserted {
                found.append(child)
                pending.append(child.id)
            }
        }
        return found
    }

    /// Whether any subagent below a task, at any depth, is waiting for an answer.
    func subagentsNeedInput(_ id: String) -> Bool {
        descendants(of: id).contains { $0.status == .waiting }
    }
}

import Foundation

extension TaskSections where Task == WireTask {
    /// Tasks matching a search the way the Mac sidebar filters, newest first.
    init(tasks: [WireTask], workspaces: [WireWorkspace], query: String) {
        let names = Dictionary(workspaces.map { ($0.id, $0.name) }, uniquingKeysWith: { $1 })
        let matching = tasks.filter { task in
            TaskSearch.matches(query, in: task.title, task.projectName, task.directory, task.workspaceID.flatMap { names[$0] })
        }
        self.init(matching.sorted(by: WireTask.newestFirst), isSettled: \.isSettled, isSnoozed: { $0.snoozedUntil != nil })
    }
}

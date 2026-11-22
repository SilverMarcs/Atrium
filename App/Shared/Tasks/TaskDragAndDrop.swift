import AtriumClient
import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers

/// Tasks dragged from the task list to another of its sections.
nonisolated struct TaskDrag: Codable, Transferable {
    let tasks: [TaskRef]

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .atriumTasks)
    }
}

extension UTType {
    /// Declared in the Mac app's Info.plist; iOS would need it too to drag tasks.
    nonisolated static let atriumTasks = UTType(exportedAs: "com.silvermarcs.atrium.tasks")
}

extension HostDirectory {
    /// The action that moves each of the tasks into the section, for those
    /// that can go there. A task named twice moves once.
    func moves(_ refs: [TaskRef], to section: TaskSection) -> [(item: HostTask, action: TaskMenuAction)] {
        var seen = Set<TaskRef>()
        return refs.filter { seen.insert($0).inserted }.compactMap(task).compactMap { item in
            item.task.menuState.action(movingTo: section).map { (item, $0) }
        }
    }
}

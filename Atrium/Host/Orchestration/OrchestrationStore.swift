import Foundation
import Observation

/// ChatGPT's delegated tasks, saved as they change so a restart doesn't lose
/// a result. Task lists observe the tasks, to list ChatGPT's sessions apart.
@MainActor
@Observable
final class OrchestrationStore {
    private(set) var tasks: [String: DelegatedTask] = [:]
    /// Tasks still running when Atrium last quit, whose sessions need opening again.
    @ObservationIgnored var resumedTaskIDs: Set<String> = []
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var isSaveScheduled = false

    /// Finished tasks are kept this long for `task_status`.
    private static let retention: TimeInterval = 7 * 24 * 60 * 60

    init(file: URL) {
        self.file = file
        guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode([DelegatedTask].self, from: data) else { return }
        tasks = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
    }

    /// Settles what Atrium was doing when it quit. A task that never reached
    /// its agent fails, since whether it did can't be known; one that did is
    /// followed again until its turn ends.
    func recoverAfterLaunch() {
        for (id, var task) in tasks where !task.state.isFinished {
            switch task.state {
            case .starting:
                task.state = .failed
                task.result = "Atrium quit while starting this task, so it may not have reached the agent. Check the session before trying again."
            case .sent:
                task.state = .running
                resumedTaskIDs.insert(id)
            default:
                resumedTaskIDs.insert(id)
            }
            task.updatedAt = .now
            tasks[id] = task
        }
        let expiry = Date.now.addingTimeInterval(-Self.retention)
        tasks = tasks.filter { !($0.value.state.isFinished && $0.value.updatedAt < expiry) }
        save()
    }

    func update(_ task: DelegatedTask) {
        tasks[task.id] = task
        save()
    }

    /// Writes once the current change is through, however many tasks it touched.
    private func save() {
        guard !isSaveScheduled else { return }
        isSaveScheduled = true
        Task {
            isSaveScheduled = false
            write()
        }
    }

    private func write() {
        guard let data = try? JSONEncoder().encode(tasks.values.sorted { $0.createdAt < $1.createdAt }) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path(percentEncoded: false))
    }
}

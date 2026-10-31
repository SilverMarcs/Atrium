import Foundation
import Observation

/// Delegated tasks and the budgets of their chains, saved as they change so
/// a restart neither loses a result nor sends one twice. Task lists observe
/// the tasks, to list delegated sessions under who started them.
@MainActor
@Observable
final class OrchestrationStore {
    private struct Saved: Codable {
        var tasks: [DelegatedTask]
        var spent: [UUID: Int]
    }

    private(set) var tasks: [String: DelegatedTask] = [:]
    /// Tasks and deliveries each chain has used.
    @ObservationIgnored private var spent: [UUID: Int] = [:]
    /// Tasks still running when Atrium last quit, whose sessions need opening again.
    @ObservationIgnored var resumedTaskIDs: Set<String> = []
    @ObservationIgnored private let file: URL
    @ObservationIgnored private var isSaveScheduled = false

    /// Finished tasks are kept this long for `task_status`.
    private static let retention: TimeInterval = 7 * 24 * 60 * 60

    init(file: URL) {
        self.file = file
        guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Saved.self, from: data) else { return }
        tasks = Dictionary(saved.tasks.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new })
        spent = saved.spent
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
        prune()
        save()
    }

    func update(_ task: DelegatedTask) {
        tasks[task.id] = task
        save()
    }

    /// Takes one unit of a chain's budget, if any is left.
    func spend(_ chainID: UUID, budget: Int) -> Bool {
        guard spent[chainID, default: 0] < budget else { return false }
        spent[chainID, default: 0] += 1
        save()
        return true
    }

    private func prune() {
        let expiry = Date.now.addingTimeInterval(-Self.retention)
        tasks = tasks.filter { _, task in
            !(task.state.isFinished && task.updatedAt < expiry && task.delivery != .pending && task.delivery != .delivering)
        }
        let chains = Set(tasks.values.map(\.chainID))
        spent = spent.filter { chains.contains($0.key) }
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
        let saved = Saved(tasks: tasks.values.sorted { $0.createdAt < $1.createdAt }, spent: spent)
        guard let data = try? JSONEncoder().encode(saved) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? data.write(to: file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path(percentEncoded: false))
    }
}

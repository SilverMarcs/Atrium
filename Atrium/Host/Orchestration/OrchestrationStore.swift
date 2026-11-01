import AtriumProtocol
import Foundation
import Observation

/// Which sessions work for which, which ones a command-line client started,
/// and the delegated turns still to report back, saved as they change so a
/// restart loses neither the links nor a result. Task lists observe it to
/// list sessions under whoever started them.
@MainActor
@Observable
final class OrchestrationStore {
    /// The session each delegated session works for, by task ID.
    var parents: [String: String] = [:] { didSet { save() } }
    /// The command-line device that started each session it started on its own, by task ID.
    var devices: [String: String] = [:] { didSet { save() } }
    /// Delegated turns not yet reported back, by the delegated session's task ID.
    var turns: [String: DelegatedTurn] = [:] { didSet { save() } }

    @ObservationIgnored private let file: URL
    @ObservationIgnored private var isSaveScheduled = false

    private nonisolated struct Contents: Codable {
        var parents: [String: String]
        var devices: [String: String]
        var turns: [String: DelegatedTurn]
    }

    init(file: URL) {
        self.file = file
        guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(Contents.self, from: data) else { return }
        parents = saved.parents
        devices = saved.devices
        turns = saved.turns
    }

    /// Writes once the current change is through, however much it touched.
    private func save() {
        guard !isSaveScheduled else { return }
        isSaveScheduled = true
        Task {
            isSaveScheduled = false
            guard let data = try? JSONEncoder().encode(Contents(parents: parents, devices: devices, turns: turns)) else { return }
            try? data.write(to: file, options: .atomic)
        }
    }
}

/// One turn a session took on for another: from the prompt Atrium relayed to
/// it until its result reaches the session that asked.
nonisolated struct DelegatedTurn: Codable, Sendable {
    enum State: String, Codable, Sendable {
        /// The prompt reached the agent; its turn hasn't been seen yet.
        case sent
        /// The agent is on it, or waiting on work it started for it.
        case running
        /// Done, with its result waiting for the session that asked to be free.
        case finished
    }

    var state: State = .sent
    /// How the turn ended, once it has.
    var outcome: AgentThreadStatus?
    /// The agent's final reply, once the turn ended.
    var result: String?
    /// Questions already passed on to the session that asked, by interaction ID.
    var askedIDs: Set<String> = []
}

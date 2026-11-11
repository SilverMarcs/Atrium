import AtriumClient
import AtriumProtocol
import Foundation

/// Follows one session's conversation and status, reporting what changed.
///
/// It only reads: following a session neither marks its result read nor tells
/// the host this device is looking at it, so alerts keep going where they would.
@MainActor
final class SessionWatch {
    enum Condition {
        /// The agent isn't working, whether it finished or needs input.
        case idle
        /// The agent is waiting for an answer to a question or approval.
        case input
        /// The turn a prompt sent after `anchor` started has finished or needs input.
        case turn(after: String?)
    }

    enum End: String, Encodable {
        case idle, input, turn, timeout, removed
    }

    let host: HostClient
    let taskID: String
    /// The conversation as reported so far, including messages the host's
    /// window of recent turns has since moved past.
    private(set) var messages: [TranscriptMessage] = []
    private var reported: [String: TranscriptMessage] = [:]
    private var reportedSession: SessionJSON?
    private var following: Task<Void, Never>?
    /// Whether the agent has worked since the watch began, which ends a turn
    /// whose prompt the transcript shows in a form not recognized.
    private var sawProcessing = false

    init(host: HostClient, taskID: String) {
        self.host = host
        self.taskID = taskID
    }

    /// Follows the conversation and waits for the host to send it.
    func start(timeout: Duration) async throws {
        let host = host, taskID = taskID
        following = Task { await host.follow(.transcript(taskID: taskID)) }
        _ = try await waitUntil(host, timeout: timeout) {
            host.conversations.transcripts[taskID] != nil || host.transcriptErrors[taskID] != nil ? true : nil
        }
        if let error = host.transcriptErrors[taskID] { throw CLIError(.failed, error) }
        guard host.conversations.transcripts[taskID] != nil else {
            throw CLIError(.unreachable, "\(host.name) didn’t send the conversation in time.")
        }
        refreshMessages()
    }

    func stop() {
        following?.cancel()
    }

    var task: WireTask? { host.task(taskID) }

    /// The newest prompt so far, which a prompt sent next is recognized after.
    var anchor: String? { messages.promptAnchor }

    /// Messages after the first prompt sent after `anchor`, that prompt included.
    func messages(fromPromptAfter anchor: String?) -> [TranscriptMessage] {
        guard let prompt = messages.prompt(1, after: anchor), let index = messages.firstIndex(where: { $0.id == prompt.id }) else { return [] }
        return Array(messages[index...])
    }

    /// Reports the session and its messages as they stand, as a follow starts with.
    func reportSnapshot(history: Int?) {
        if let task { report(.session(host.json(task))) }
        reportedSession = task.map(host.json)
        let shown = history.map { Array(messages.suffix($0)) } ?? messages
        for message in messages { reported[message.id] = message }
        for message in shown { report(.message(MessageJSON(message))) }
    }

    /// Takes in what's already there without reporting it.
    func markReported() {
        reportedSession = task.map(host.json)
        for message in messages { reported[message.id] = message }
    }

    /// Reports changes until `condition` holds, the session goes away or
    /// `timeout` passes. With `isReporting` off it only waits.
    func run(until condition: Condition?, timeout: Duration?, isReporting: Bool) async throws -> End {
        let changes = host.changes()
        if let end = check(condition) { return end }
        let end = try await deadline(timeout) { () async throws -> End in
            for await change in changes {
                switch change {
                case .revoked(let message):
                    throw CLIError(.revoked, message)
                case .state(let state):
                    if isReporting { self.report(.connection(state)) }
                case .event(.transcriptUnavailable(let id, let message)) where id == self.taskID:
                    if isReporting { self.report(.unavailable(message)) }
                case .event(.transcript(let id, _)), .event(.transcriptChanged(let id, _)):
                    guard id == self.taskID else { continue }
                    self.refreshMessages()
                    if isReporting { self.reportMessages() }
                case .event(.tasks), .event(.tasksChanged):
                    guard let task = self.task else { return .removed }
                    if task.status == .processing { self.sawProcessing = true }
                    let session = self.host.json(task)
                    if isReporting, session != self.reportedSession { self.report(.session(session)) }
                    self.reportedSession = session
                default:
                    continue
                }
                if let end = self.check(condition) { return end }
            }
            throw CLIError(.failed, "Stopped following \(self.host.name).")
        }
        return end ?? .timeout
    }

    private func check(_ condition: Condition?) -> End? {
        guard let condition else { return nil }
        guard let task else { return .removed }
        switch condition {
        case .idle:
            return task.status != .processing ? .idle : nil
        case .input:
            return task.needsInput ? .input : nil
        case .turn(let anchor):
            if task.needsInput { return .input }
            guard task.status != .processing else { return nil }
            if sawProcessing { return .turn }
            guard let prompt = messages.prompt(1, after: anchor),
                  let index = messages.firstIndex(where: { $0.id == prompt.id }) else { return nil }
            let replied = messages[(index + 1)...].contains { $0.role == .assistant }
            return replied || task.status == .failed || task.status == .stopped ? .turn : nil
        }
    }

    private func refreshMessages() {
        messages = messages.extended(by: host.conversations.transcripts[taskID] ?? [])
    }

    private func reportMessages() {
        for message in messages where reported[message.id] != message {
            reported[message.id] = message
            report(.message(MessageJSON(message)))
        }
        let current = Set(messages.map(\.id))
        let removed = reported.keys.filter { !current.contains($0) }.sorted()
        guard !removed.isEmpty else { return }
        for id in removed { reported[id] = nil }
        report(.removed(removed))
    }

    func report(_ event: WatchEvent) {
        Output.write(event)
    }
}

/// One line of a followed session's stream.
enum WatchEvent: Encodable {
    case session(SessionJSON)
    case message(MessageJSON)
    case removed([String])
    case connection(HostClient.State)
    case unavailable(String)
    case end(SessionWatch.End)

    private enum CodingKeys: String, CodingKey {
        case type, session, message, messageIDs, state, reason
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .session(let session):
            try container.encode("session", forKey: .type)
            try container.encode(session, forKey: .session)
        case .message(let message):
            try container.encode("message", forKey: .type)
            try container.encode(message, forKey: .message)
        case .removed(let ids):
            try container.encode("removed", forKey: .type)
            try container.encode(ids, forKey: .messageIDs)
        case .connection(let state):
            try container.encode("connection", forKey: .type)
            switch state {
            case .connecting: try container.encode("connecting", forKey: .state)
            case .connected: try container.encode("connected", forKey: .state)
            case .offline(let reason):
                try container.encode("offline", forKey: .state)
                try container.encode(reason, forKey: .reason)
            }
        case .unavailable(let message):
            try container.encode("unavailable", forKey: .type)
            try container.encode(message, forKey: .reason)
        case .end(let end):
            try container.encode("end", forKey: .type)
            try container.encode(end, forKey: .reason)
        }
    }
}

extension WireTask {
    /// Whether a question or approval is waiting for an answer. An agent can
    /// report needing input in passing without asking anything, which doesn't count.
    var needsInput: Bool { !interactions.isEmpty }
}

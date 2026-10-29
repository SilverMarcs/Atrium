import AtriumProtocol
import Foundation

/// One client of this host: the Mac's own UI in process, or a device through
/// the relay. Holds its authentication and subscriptions and sends it events,
/// turning task and transcript states into changes against what it last got.
@MainActor
final class ServerConnection {
    let id = UUID()
    let isLocal: Bool
    private(set) var device: ClientDevice?
    private(set) var topics: Set<HostTopic> = []
    /// Whether this client has said if it's in the foreground, which makes it
    /// one that alerts are routed by.
    var reportsActivity = false
    private var sentTasks: WireTasksSnapshot?
    private var sentTranscripts: [String: [TranscriptMessage]] = [:]
    private let send: (HostEvent) -> Void
    private let closeChannel: () -> Void

    var isAuthenticated: Bool { isLocal || device != nil }

    init(isLocal: Bool, send: @escaping (HostEvent) -> Void, close: @escaping () -> Void = {}) {
        self.isLocal = isLocal
        self.send = send
        closeChannel = close
    }

    func authenticated(as device: ClientDevice) {
        self.device = device
    }

    func close() {
        closeChannel()
    }

    func subscribe(_ topic: HostTopic) {
        topics.insert(topic)
        switch topic {
        case .tasks: sentTasks = nil
        case .transcript(let taskID): sentTranscripts[taskID] = nil
        default: break
        }
    }

    func unsubscribe(_ topic: HostTopic) {
        topics.remove(topic)
        if case .transcript(let taskID) = topic { sentTranscripts[taskID] = nil }
    }

    func sendHello(_ hello: HostHello) {
        send(.hello(hello))
    }

    /// Sends a topic's latest state, if this client follows it.
    func deliver(_ event: HostEvent, for topic: HostTopic) {
        guard isAuthenticated, topics.contains(topic) else { return }
        switch event {
        case .tasks(let snapshot):
            push(tasks: snapshot)
        case .transcript(let taskID, let messages):
            push(transcript: messages, of: taskID)
        default:
            send(event)
        }
    }

    /// Sends the first snapshot in full and only what changed after that.
    private func push(tasks snapshot: WireTasksSnapshot) {
        if let sentTasks {
            let delta = WireTasksDelta(from: sentTasks, to: snapshot)
            guard !delta.isEmpty else { return }
            send(.tasksChanged(delta))
        } else {
            send(.tasks(snapshot))
        }
        sentTasks = snapshot
    }

    /// Sends a task's recent turns first, then only messages that changed.
    ///
    /// The transcript is a window over the last turns, so each new turn pushes the
    /// oldest one out. The client keeps what it already shows instead: removing
    /// it would shift the timeline under a reader scrolled up. Only messages that
    /// leave the window from its end, as a rolled-back turn does, are removed.
    private func push(transcript messages: [TranscriptMessage], of taskID: String) {
        if let sent = sentTranscripts[taskID] {
            let held = sent.extended(by: messages)
            let delta = WireTranscriptDelta(from: sent, to: held)
            guard !delta.isEmpty else { return }
            send(.transcriptChanged(taskID: taskID, delta: delta))
            sentTranscripts[taskID] = held
        } else {
            send(.transcript(taskID: taskID, messages: messages))
            sentTranscripts[taskID] = messages
        }
    }
}

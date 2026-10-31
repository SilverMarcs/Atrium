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
    private var sentTasks: WireTasksSnapshot?
    private var sentTranscripts: [String: [TranscriptMessage]] = [:]
    private var sentTerminals: [String: WireTerminalFrame] = [:]
    private var awaitingTerminalAck: Set<String> = []
    private var pendingTerminals: [String: WireTerminalFrame] = [:]
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
        case .terminal(let taskID):
            sentTerminals[taskID] = nil
            pendingTerminals[taskID] = nil
            awaitingTerminalAck.remove(taskID)
        default: break
        }
    }

    func unsubscribe(_ topic: HostTopic) {
        topics.remove(topic)
        if case .transcript(let taskID) = topic { sentTranscripts[taskID] = nil }
        if case .terminal(let taskID) = topic {
            sentTerminals[taskID] = nil
            pendingTerminals[taskID] = nil
            awaitingTerminalAck.remove(taskID)
        }
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
        case .terminal(let taskID, let frame):
            push(terminal: frame, of: taskID)
        case .terminalUnavailable(let taskID, _):
            sentTerminals[taskID] = nil
            pendingTerminals[taskID] = nil
            awaitingTerminalAck.remove(taskID)
            send(event)
        default:
            send(event)
        }
    }

    /// Only one terminal frame is in flight per task. New output replaces the
    /// pending frame; its delta is computed against what the client actually got.
    private func push(terminal frame: WireTerminalFrame, of taskID: String) {
        if awaitingTerminalAck.contains(taskID) {
            pendingTerminals[taskID] = frame
            return
        }
        guard sentTerminals[taskID] != frame else { return }
        let previous = sentTerminals[taskID]
        sentTerminals[taskID] = frame
        awaitingTerminalAck.insert(taskID)
        send(.terminal(taskID: taskID, frame: frame.changes(since: previous)))
    }

    func acknowledgeTerminal(taskID: String, terminalID: UUID, sequence: UInt64) {
        guard let sent = sentTerminals[taskID], sent.terminalID == terminalID,
              sent.sequence == sequence, awaitingTerminalAck.remove(taskID) != nil else { return }
        if let pending = pendingTerminals.removeValue(forKey: taskID) {
            push(terminal: pending, of: taskID)
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

import Foundation

/// One client of this host: the Mac's own UI in process, a device through
/// the relay, or an agent's tool call. Holds its authentication and subscriptions and sends it events,
/// turning task, transcript and command output states into changes against
/// what it last got.
@MainActor
final class ServerConnection {
    let id = UUID()
    let isLocal: Bool
    private(set) var device: ClientDevice?
    private(set) var topics: Set<HostTopic> = []
    /// Whether this client has said if it's in the foreground, which makes it
    /// one that alerts are routed by.
    var activity: ClientActivity?
    var reportsActivity: Bool { activity != nil }
    private var sentTasks: WireTasksSnapshot?
    private var sentTranscripts: [String: [TranscriptMessage]] = [:]
    private var sentOutputs: [HostTopic: WireCommandOutput] = [:]
    private let send: (HostEvent) -> Void
    private let closeChannel: () -> Void

    /// The session an agent on this Mac calls a tool from, which what it
    /// starts and prompts reports back to.
    var caller: String?

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
        case .commandOutput, .backgroundSessionOutput: sentOutputs[topic] = nil
        default: break
        }
    }

    func unsubscribe(_ topic: HostTopic) {
        topics.remove(topic)
        if case .transcript(let taskID) = topic { sentTranscripts[taskID] = nil }
        if case .commandOutput = topic { sentOutputs[topic] = nil }
        if case .backgroundSessionOutput = topic { sentOutputs[topic] = nil }
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
        case .commandOutput(let workspaceID, let commandID, let output):
            if let change = nextOutput(output, for: topic) {
                send(.commandOutput(workspaceID: workspaceID, commandID: commandID, output: change))
            }
        case .backgroundSessionOutput(let workspaceID, let sessionID, let output):
            if let change = nextOutput(output, for: topic) {
                send(.backgroundSessionOutput(workspaceID: workspaceID, sessionID: sessionID, output: change))
            }
        default:
            send(event)
        }
    }

    /// Returns output in full first, then from the last line sent (which may have been unfinished),
    /// or nil when nothing changed.
    private func nextOutput(_ output: WireCommandOutput, for topic: HostTopic) -> WireCommandOutput? {
        let sent = sentOutputs[topic]
        guard sent != output else { return nil }
        sentOutputs[topic] = output
        if let sent, sent.id == output.id, sent.end > output.firstLine {
            return output.changes(from: sent.end - 1)
        }
        return output
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

    /// Sends a task's whole conversation first, then only messages that changed.
    private func push(transcript messages: [TranscriptMessage], of taskID: String) {
        if let sent = sentTranscripts[taskID] {
            let delta = WireTranscriptDelta(from: sent, to: messages)
            guard !delta.isEmpty else { return }
            send(.transcriptChanged(taskID: taskID, delta: delta))
            sentTranscripts[taskID] = messages
        } else {
            send(.transcript(taskID: taskID, messages: messages))
            sentTranscripts[taskID] = messages
        }
    }
}

extension ClientDevice {
    /// The agents this Mac runs, as their tool calls act.
    static let localAgents = ClientDevice(
        id: UUID(uuidString: "A7B1C2D3-0000-4000-8000-0000000A6E75") ?? UUID(), name: "Local agents", kind: .agent
    )
}

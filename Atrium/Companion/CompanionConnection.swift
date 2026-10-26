import Foundation

/// One companion on one channel: decodes its requests, holds its
/// authentication and subscriptions, and sends it events. Task updates are
/// sent as deltas against what this connection last received.
@MainActor
final class CompanionConnection {
    let id = UUID()
    private let channel: any CompanionChannel
    private weak var server: CompanionServer?
    private(set) var device: CompanionDevice?
    private(set) var topics: Set<CompanionTopic> = []
    private var sentTasks: WireTasksSnapshot?
    private var sentTranscripts: [String: [TranscriptMessage]] = [:]

    var isAuthenticated: Bool { device != nil }

    init(channel: any CompanionChannel, server: CompanionServer) {
        self.channel = channel
        self.server = server
    }

    func start(hostName: String, onClose: @escaping (CompanionConnection) -> Void) {
        channel.onReady = { [weak self] in
            self?.send(.event(.hello(hostName: hostName, protocolVersion: CompanionProtocol.version)))
        }
        channel.onMessage = { [weak self] data in self?.receive(data) }
        channel.onClose = { [weak self] _ in
            guard let self else { return }
            onClose(self)
        }
        channel.start()
    }

    func close() {
        channel.close()
    }

    func subscribe(_ topic: CompanionTopic) {
        topics.insert(topic)
        switch topic {
        case .tasks: sentTasks = nil
        case .transcript(let taskID): sentTranscripts[taskID] = nil
        case .git, .commands: break
        }
    }

    func unsubscribe(_ topic: CompanionTopic) {
        topics.remove(topic)
        if case .transcript(let taskID) = topic { sentTranscripts[taskID] = nil }
    }

    /// Sends a task's recent turns first, then only messages that changed.
    ///
    /// The transcript is a window over the last turns, so each new turn pushes the
    /// oldest one out. The companion keeps what it already shows instead: removing
    /// it would shift the timeline under a reader scrolled up. Only messages that
    /// leave the window from its end, as a rolled-back turn does, are removed.
    func push(transcript messages: [TranscriptMessage], of taskID: String) {
        guard topics.contains(.transcript(taskID: taskID)) else { return }
        if let sent = sentTranscripts[taskID] {
            var held = messages
            if let first = messages.first, let start = sent.firstIndex(where: { $0.id == first.id }) {
                held.insert(contentsOf: sent[..<start], at: 0)
            }
            let delta = WireTranscriptDelta(from: sent, to: held)
            guard !delta.isEmpty else { return }
            send(.event(.transcriptChanged(taskID: taskID, delta: delta)))
            sentTranscripts[taskID] = held
        } else {
            send(.event(.transcript(taskID: taskID, messages: messages)))
            sentTranscripts[taskID] = messages
        }
    }

    func authenticated(as device: CompanionDevice) {
        self.device = device
    }

    /// Sends the first snapshot in full and only what changed after that.
    func push(tasks snapshot: WireTasksSnapshot) {
        guard topics.contains(.tasks) else { return }
        if let sentTasks {
            let delta = WireTasksDelta(from: sentTasks, to: snapshot)
            guard !delta.isEmpty else { return }
            send(.event(.tasksChanged(delta)))
        } else {
            send(.event(.tasks(snapshot)))
        }
        sentTasks = snapshot
    }

    func push(_ event: CompanionEvent) {
        send(.event(event))
    }

    private func receive(_ data: Data) {
        guard let frame = try? CompanionCodec.decode(ClientFrame.self, from: data) else {
            channel.close()
            return
        }
        Task { [weak self] in
            guard let self, let server = self.server else { return }
            let reply = await server.handle(frame.request, from: self)
            self.send(.reply(id: frame.id, reply: reply))
        }
    }

    private func send(_ frame: ServerFrame) {
        guard let data = try? CompanionCodec.encode(frame) else { return }
        channel.send(data)
    }
}

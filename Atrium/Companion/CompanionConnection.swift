import Foundation

/// One companion on one channel: decodes its requests, holds its
/// authentication and subscriptions, and sends it events. Task updates are
/// sent as deltas against what this connection last received.
@MainActor
final class CompanionConnection {
    private let channel: any CompanionChannel
    private weak var server: CompanionServer?
    private(set) var device: CompanionDevice?
    private(set) var topics: Set<CompanionTopic> = []
    private var sentTasks: WireTasksSnapshot?

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
        if topic == .tasks { sentTasks = nil }
    }

    func unsubscribe(_ topic: CompanionTopic) {
        topics.remove(topic)
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

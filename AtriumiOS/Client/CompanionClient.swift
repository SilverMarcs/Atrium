import Foundation
import Observation

/// The companion's connection to a paired Mac and the state it mirrors.
///
/// Views declare what they need with `follow(_:)`; the client subscribes while
/// any view follows a topic and resubscribes after reconnecting, so screens
/// never manage the connection themselves. Requests are async and resolve
/// with the Mac's reply.
@MainActor
@Observable
final class CompanionClient {
    private(set) var state: CompanionConnectionState = .idle
    private(set) var hosts: [DiscoveredHost] = []
    private(set) var pairedHostName: String?
    private(set) var tasks: WireTasksSnapshot?
    private(set) var gitStatuses: [UUID: WireGitStatus] = [:]
    private(set) var commands: [UUID: [WireCommand]] = [:]
    /// The latest failed action, shown as an alert.
    var actionError: String?
    /// A task to navigate to, from a notification tap or a task just created.
    var pendingTaskID: String?

    var isPaired: Bool { pairedHostName != nil }
    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    /// Paired but without a live connection, so screens show cached state.
    var isReconnecting: Bool { isPaired && !isConnected }

    @ObservationIgnored private let browser = HostBrowser()
    @ObservationIgnored private let notifier = TaskAttentionNotifier()
    @ObservationIgnored private var channel: (any CompanionChannel)?
    @ObservationIgnored private var pending: [UInt32: CheckedContinuation<CompanionReply, any Error>] = [:]
    @ObservationIgnored private var nextRequestID: UInt32 = 0
    @ObservationIgnored private var topicCounts: [CompanionTopic: Int] = [:]
    @ObservationIgnored private var icons: [String: Data] = [:]
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?

    private static let reconnectDelay: Duration = .seconds(2)

    init() {
        pairedHostName = CompanionCredentials.hostName
    }

    func start() {
        browser.onChange = { [weak self] hosts in
            self?.hosts = hosts
            self?.connectToPairedHost()
        }
        browser.start()
    }

    func pair(with host: DiscoveredHost, code: String) {
        connect(to: host, authentication: .pair(code: code))
    }

    /// Forgets the paired Mac. Pairing again needs a fresh code from its Settings.
    func unpair() {
        CompanionCredentials.forget()
        pairedHostName = nil
        closeChannel()
        state = .idle
        tasks = nil
        gitStatuses = [:]
        commands = [:]
    }

    func sceneDidBecomeActive() {
        connectToPairedHost()
    }

    // MARK: - Topics

    /// Keeps `topic` subscribed until the calling task is cancelled. Call from `.task`.
    func follow(_ topic: CompanionTopic) async {
        topicCounts[topic, default: 0] += 1
        if topicCounts[topic] == 1, isConnected { subscribe(topic) }
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(3600))
        }
        let remaining = (topicCounts[topic] ?? 1) - 1
        topicCounts[topic] = remaining > 0 ? remaining : nil
        if remaining <= 0, isConnected {
            Task { try? await request(.unsubscribe(topic)) }
        }
    }

    private func subscribe(_ topic: CompanionTopic) {
        Task { try? await request(.subscribe(topic)) }
    }

    // MARK: - Requests

    func request(_ request: CompanionRequest) async throws -> CompanionReply {
        guard let channel else { throw CompanionClientError.notConnected }
        nextRequestID &+= 1
        let id = nextRequestID
        let data = try CompanionCodec.encode(ClientFrame(id: id, request: request))
        let reply = try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            channel.send(data)
        }
        if case .failed(let message) = reply { throw CompanionClientError.rejected(message) }
        return reply
    }

    /// Sends a request whose only result is success, reporting failures as `actionError`.
    func send(_ request: CompanionRequest) {
        Task { await perform(request) }
    }

    @discardableResult
    func perform(_ request: CompanionRequest) async -> CompanionReply? {
        do {
            return try await self.request(request)
        } catch {
            actionError = error.localizedDescription
            return nil
        }
    }

    /// Performs a task menu action. Rename and delete need confirmation first,
    /// so screens handle those; a fork opens once it's created.
    func perform(_ action: TaskMenuAction, on task: WireTask) {
        let request: CompanionTaskAction
        switch action {
        case .settle: request = .settle
        case .restore: request = .restore
        case .snooze:
            guard let date = Calendar.current.date(byAdding: .day, value: 1, to: .now) else { return }
            request = .snooze(until: date)
        case .unsnooze: request = .unsnooze
        case .markRead: request = .markRead
        case .markUnread: request = .markUnread
        case .fork:
            Task {
                if case .task(let id) = await perform(.task(id: task.id, action: .fork)) { pendingTaskID = id }
            }
            return
        case .rename, .delete:
            return
        }
        send(.task(id: task.id, action: request))
    }

    /// A custom project icon, fetched once and cached for the session.
    func icon(forKey key: String) async -> Data? {
        if let data = icons[key] { return data }
        guard case .icon(let data) = try? await request(.icon(key: key)) else { return nil }
        icons[key] = data
        return data
    }

    func workspace(_ id: UUID?) -> WireWorkspace? {
        tasks?.workspaces.first { $0.id == id }
    }

    func task(_ id: String) -> WireTask? {
        tasks?.tasks.first { $0.id == id }
    }

    // MARK: - Connection

    private enum Authentication {
        case pair(code: String)
        case token(String)
    }

    private func connectToPairedHost() {
        guard channel == nil, reconnectTask == nil, let pairedHostName, let token = CompanionCredentials.token,
              let host = hosts.first(where: { $0.name == pairedHostName }) else { return }
        connect(to: host, authentication: .token(token))
    }

    private func connect(to host: DiscoveredHost, authentication: Authentication) {
        closeChannel()
        state = .connecting(hostName: host.name)
        let channel = FramedTCPChannel(endpoint: host.endpoint)
        self.channel = channel
        channel.onReady = { [weak self] in
            Task { await self?.authenticate(authentication, hostName: host.name) }
        }
        channel.onMessage = { [weak self] data in self?.receive(data) }
        channel.onClose = { [weak self, weak channel] reason in
            guard let self, let channel, self.channel === channel else { return }
            self.channelDidClose(reason)
        }
        channel.start()
    }

    private func authenticate(_ authentication: Authentication, hostName: String) async {
        do {
            switch authentication {
            case .pair(let code):
                guard case .paired(let token) = try await request(.pair(code: code, device: CompanionCredentials.device)) else {
                    throw CompanionClientError.unexpectedReply
                }
                CompanionCredentials.save(hostName: hostName, token: token)
                pairedHostName = hostName
            case .token(let token):
                _ = try await request(.authenticate(token: token, deviceID: CompanionCredentials.device.id))
            }
            state = .connected(hostName: hostName)
            notifier.requestAuthorization()
            for topic in topicCounts.keys { subscribe(topic) }
        } catch {
            switch (authentication, error) {
            case (.token, CompanionClientError.rejected):
                // The Mac revoked this phone; staying paired would retry forever.
                unpair()
                state = .failed(error.localizedDescription)
            case (.token, _):
                channelDidClose(error.localizedDescription)
            case (.pair, _):
                closeChannel()
                state = .failed(error.localizedDescription)
            }
        }
    }

    private func channelDidClose(_ reason: String?) {
        closeChannel()
        state = .failed(reason ?? CompanionClientError.disconnected.localizedDescription)
        guard isPaired else { return }
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: Self.reconnectDelay)
            self?.reconnectTask = nil
            self?.connectToPairedHost()
        }
    }

    private func closeChannel() {
        reconnectTask?.cancel()
        reconnectTask = nil
        let channel = channel
        self.channel = nil
        channel?.close()
        for continuation in pending.values {
            continuation.resume(throwing: CompanionClientError.disconnected)
        }
        pending.removeAll()
    }

    private func receive(_ data: Data) {
        guard let frame = try? CompanionCodec.decode(ServerFrame.self, from: data) else { return }
        switch frame {
        case .reply(let id, let reply):
            pending.removeValue(forKey: id)?.resume(returning: reply)
        case .event(let event):
            apply(event)
        }
    }

    private func apply(_ event: CompanionEvent) {
        switch event {
        case .hello:
            break
        case .tasks(let snapshot):
            notifier.notify(from: tasks, to: snapshot)
            tasks = snapshot
        case .tasksChanged(let delta):
            guard var snapshot = tasks else { return }
            snapshot.apply(delta)
            notifier.notify(from: tasks, to: snapshot)
            tasks = snapshot
        case .git(let workspaceID, let status):
            gitStatuses[workspaceID] = status
        case .commands(let workspaceID, let commands):
            self.commands[workspaceID] = commands
        }
    }
}

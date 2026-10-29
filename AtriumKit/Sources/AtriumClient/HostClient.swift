import AtriumProtocol
import Foundation
import Observation

/// One host as a client sees it: the connection, and the state it mirrors.
///
/// Callers declare what they need with `follow(_:)`; the client subscribes
/// while anything follows a topic and resubscribes after reconnecting, so no
/// caller manages the connection itself. A host that can't be reached keeps
/// showing what was last received. Requests are async and resolve with the
/// host's reply.
///
/// Following a task's conversation only reads it. A client acknowledges a
/// task's result, or tells the host which task it shows, only when it says so
/// with `setActivity(_:)` or a request.
@MainActor
@Observable
public final class HostClient: Identifiable {
    public nonisolated enum State: Equatable, Sendable {
        case connecting
        case connected
        case offline(String)
    }

    /// How a paired host is reached.
    public nonisolated enum Route: Sendable {
        case localNetwork
        case relay
    }

    enum Authentication {
        /// The Mac's own host, in process.
        case none
        case pair(secret: String)
        case token(String)
    }

    public let id: String
    /// Whether this is the host running in this app, which alone can change
    /// files and projects and show terminals.
    public let isLocal: Bool
    public private(set) var pairedHost: PairedHost?
    /// A name the user chose for this Mac's own host, shown instead of its own.
    public private(set) var customLocalName: String?
    public private(set) var state: State = .connecting {
        didSet { if state != oldValue { notify(.state(state)) } }
    }
    /// How the connection in use reaches a paired host.
    public private(set) var route: Route?
    public private(set) var hello: HostHello?
    /// The latest failed action, shown as an alert.
    public var actionError: String?

    private var hostTasks: WireTasksSnapshot?
    private var taskUpdates: [OptimisticTaskUpdate] = []
    /// The host's tasks, projects and agents, with actions this client sent
    /// shown before the host confirms them.
    public var tasks: WireTasksSnapshot? {
        guard var snapshot = hostTasks else { return nil }
        for update in taskUpdates { update.apply(to: &snapshot) }
        return snapshot
    }
    public private(set) var gitStatuses: [GitScope: [GitRepositoryStatus]] = [:]
    public private(set) var commands: [UUID: [WireCommand]] = [:]
    /// Entries of followed folders, by their `.directory` topic.
    public private(set) var directories: [HostTopic: [FileEntry]] = [:]
    /// The host's remote access, while its own Mac UI follows it.
    public private(set) var remoteAccess: WireRemoteAccess?
    /// Bumped each time a followed file changes on the host, by its `.file` topic.
    public private(set) var fileRevisions: [HostTopic: Int] = [:]
    public let conversations = ConversationStore()
    /// Why a followed conversation couldn't be loaded, by task.
    public private(set) var transcriptErrors: [String: String] = [:]
    /// New tasks opened on this device, by draft ID. One stays after its first
    /// prompt until the task list shows the task the host created for it.
    public internal(set) var drafts: [String: TaskDraft] = [:]

    /// Called as the transcript takes over showing a prompt sent from this
    /// device, with the message that now shows it, so a send animation still
    /// running carries on in that message's row.
    @ObservationIgnored public var onPendingPromptShown: ((PendingPrompt.ID, TranscriptMessage.ID) -> Void)?
    @ObservationIgnored weak var connections: HostConnections?

    /// Connects to the Mac's own host; nil for a paired host.
    @ObservationIgnored private let loopback: (@MainActor () -> any HostConnection)?
    @ObservationIgnored private var connectingRoute: Route?
    /// Set after the local network failed, until the host is found there again.
    @ObservationIgnored private var skipsLocalNetwork = false
    @ObservationIgnored private var authentication: Authentication
    @ObservationIgnored private var connection: (any HostConnection)?
    /// The relay channel under `connection`, which can wait for the host to come online.
    @ObservationIgnored private weak var relayChannel: RelayClientChannel?
    @ObservationIgnored private var activity = ClientActivity(isActive: false, taskID: nil)
    /// How many callers follow each topic. Every client always follows a host's tasks.
    @ObservationIgnored private var topicCounts: [HostTopic: Int] = [.tasks: 1]
    @ObservationIgnored private var icons: [String: Data] = [:]
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var failedAttempts = 0
    @ObservationIgnored private let localName: String
    @ObservationIgnored private var observers: [UUID: AsyncStream<HostClientChange>.Continuation] = [:]

    /// The Mac's own host.
    public init(localID: String, name: String, connection: @escaping @MainActor () -> any HostConnection) {
        id = localID
        isLocal = true
        localName = name
        loopback = connection
        authentication = .none
    }

    /// A host reached through the relay.
    init(paired host: PairedHost, authentication: Authentication) {
        id = host.id
        isLocal = false
        pairedHost = host
        localName = host.hostName
        loopback = nil
        self.authentication = authentication
    }

    public var name: String { pairedHost?.displayName ?? customLocalName ?? hello?.hostName ?? localName }
    /// What an empty rename goes back to: the host's own name.
    public var defaultName: String { pairedHost?.hostName ?? hello?.hostName ?? localName }
    public var isConnected: Bool { state == .connected }
    /// Whether the relay is holding a connection until the host comes online.
    private var isWaitingForHost: Bool {
        if case .offline = state { connection != nil } else { false }
    }
    public var isPairing: Bool { if case .pair = authentication { true } else { false } }
    /// Whether the host speaks a newer protocol than this app.
    public var needsAppUpdate: Bool { (hello?.protocolVersion ?? 0) > HostProtocol.version }

    // MARK: - Connection

    /// Connects, and keeps reconnecting while the host can't be reached.
    public func start() {
        connect()
    }

    /// Tries the host again now instead of waiting out the retry delay.
    public func retryNow() {
        guard !isConnected else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        failedAttempts = 0
        // A connection waiting at the relay may have died unnoticed, as while
        // the app was suspended.
        if isWaitingForHost { stop() }
        connect()
    }

    public func stop() {
        reconnectTask?.cancel()
        reconnectTask = nil
        connection?.close()
        connection = nil
        route = nil
    }

    public func rename(to name: String?) {
        if isLocal { customLocalName = name }
        guard var host = pairedHost else { return }
        host.customName = name
        pairedHost = host
    }

    /// The host's own Mac connects in process; a paired host directly when
    /// it's on the local network, else through the relay.
    private func makeConnection() -> any HostConnection {
        relayChannel = nil
        if let loopback {
            connectingRoute = nil
            return loopback()
        }
        guard let pairedHost else { preconditionFailure("A remote host is always paired") }
        #if canImport(Network)
        if !skipsLocalNetwork, let endpoint = connections?.localEndpoint(for: id) {
            connectingRoute = .localNetwork
            return RemoteHostConnection(host: pairedHost, over: FramedChannel(endpoint: endpoint))
        }
        #endif
        connectingRoute = .relay
        // A paired host that's offline is waited for at the relay; pairing fails instead.
        let relay = RelayClientChannel(hostID: id, waitsForHost: !isPairing)
        relay.onHostOffline = { [weak self, weak relay] reason in
            guard let self, let relay, self.relayChannel === relay else { return }
            self.hostIsOffline(reason)
        }
        relayChannel = relay
        return RemoteHostConnection(host: pairedHost, over: relay)
    }

    /// The relay holds the connection until the host comes online, so this
    /// client shows it offline without retrying.
    private func hostIsOffline(_ reason: String) {
        ClientLog.info("Waiting for \(name) to come online")
        state = .offline(reason)
    }

    /// The host appeared on or left the local network. A connection through the
    /// relay moves to the local network as soon as the host is found there.
    func localNetworkChanged() {
        skipsLocalNetwork = false
        guard !isLocal, !isPairing, connections?.isOnLocalNetwork(id) == true, route != .localNetwork else { return }
        stop()
        connect()
    }

    private func connect() {
        guard connection == nil, reconnectTask == nil else { return }
        // Nothing to try without a network; the connections retry once there is one.
        if !isLocal, connections?.hasNetwork == false {
            let reason = "This device isn’t connected to a network."
            if isPairing { connections?.pairingFailed(self, message: reason) } else { state = .offline(reason) }
            return
        }
        state = .connecting
        let connection = makeConnection()
        self.connection = connection
        connection.onEvent = { [weak self, weak connection] event in
            guard let self, self.connection === connection else { return }
            self.apply(event)
        }
        connection.onReady = { [weak self, weak connection] in
            guard let self, self.connection === connection else { return }
            Task { await self.authenticate() }
        }
        connection.onClose = { [weak self, weak connection] reason in
            guard let self, self.connection === connection else { return }
            self.connectionDidClose(reason)
        }
        connection.start()
    }

    private func authenticate() async {
        guard let authenticating = connection else { return }
        do {
            switch authentication {
            case .none:
                break
            case .pair(let secret):
                guard let credentials = connections?.credentials else { throw HostClientError.notConnected }
                let reply = try await authenticating.request(.pair(secret: secret, device: credentials.device), key: nil)
                if case .failed(let message) = reply { throw HostClientError.rejected(message) }
                guard case .paired(let token) = reply else { throw HostClientError.unexpectedReply }
                if let pairedHost { try credentials.save(pairedHost, token: token) }
                authentication = .token(token)
                connections?.didPair(self)
            case .token(let token):
                guard let device = connections?.credentials.device else { throw HostClientError.notConnected }
                let reply = try await authenticating.request(.authenticate(token: token, deviceID: device.id), key: nil)
                if case .failed(let message) = reply { throw HostClientError.rejected(message) }
            }
            guard connection === authenticating else { return }
            ClientLog.info("Connected to \(name)")
            route = connectingRoute
            state = .connected
            failedAttempts = 0
            if activity.isActive || activity.taskID != nil { send(.activity(activity)) }
            connections?.delegate?.hostDidConnect(self)
            for topic in topicCounts.keys { subscribe(topic) }
            // Found nearby while connecting through the relay, as during pairing.
            if route == .relay, !skipsLocalNetwork, connections?.isOnLocalNetwork(id) == true { localNetworkChanged() }
        } catch {
            guard connection === authenticating else { return }
            switch (authentication, error) {
            case (.pair, _):
                stop()
                connections?.pairingFailed(self, message: error.localizedDescription)
            case (.token, HostClientError.rejected(let message)):
                // The host revoked this device; staying paired would retry forever.
                stop()
                state = .offline(message)
                notify(.revoked(message))
                connections?.forget(self, reason: message)
            default:
                connectionDidClose(error.localizedDescription)
            }
        }
    }

    private func connectionDidClose(_ reason: String?) {
        connection = nil
        route = nil
        let reason = reason ?? HostClientError.disconnected.localizedDescription
        ClientLog.info("Lost \(name): \(reason)")
        // A host found on the local network but not reachable there is tried
        // through the relay straight away.
        if connectingRoute == .localNetwork {
            skipsLocalNetwork = true
            connect()
            return
        }
        if isPairing {
            connections?.pairingFailed(self, message: reason)
            return
        }
        state = .offline(reason)
        guard connections?.hasNetwork != false else { return }
        // Back off while the host stays unreachable, up to half a minute between tries.
        failedAttempts += 1
        let delay = Duration.seconds(min(2 << min(failedAttempts - 1, 4), 30))
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.reconnectTask = nil
            self?.connect()
        }
    }

    // MARK: - Activity

    /// Tells the host whether this client is in use and which of its tasks it
    /// shows, which routes alerts and counts that task as read. Clients that
    /// never call this stay out of both.
    public func setActivity(_ activity: ClientActivity) {
        guard activity != self.activity else { return }
        self.activity = activity
        if isConnected { send(.activity(activity)) }
    }

    // MARK: - Topics

    /// Keeps `topic` subscribed until the calling task is cancelled. Call from `.task`.
    public func follow(_ topic: HostTopic) async {
        topicCounts[topic, default: 0] += 1
        if topicCounts[topic] == 1, isConnected { subscribe(topic) }
        await Task.waitUntilCancelled()
        let remaining = (topicCounts[topic] ?? 1) - 1
        topicCounts[topic] = remaining > 0 ? remaining : nil
        if remaining <= 0, isConnected {
            Task { try? await request(.unsubscribe(topic)) }
        }
    }

    /// Subscribes again, which has the host reload what it can.
    public func reload(_ topic: HostTopic) {
        if case .transcript(let taskID) = topic { transcriptErrors[taskID] = nil }
        if isConnected { subscribe(topic) }
    }

    private func subscribe(_ topic: HostTopic) {
        Task { try? await request(.subscribe(topic)) }
    }

    // MARK: - Changes

    /// Every change of connection state and every event the host sends, each
    /// after this client has applied it, until the stream is dropped.
    public func changes() -> AsyncStream<HostClientChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: HostClientChange.self)
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.observers[id] = nil }
        }
        return stream
    }

    private func notify(_ change: HostClientChange) {
        for observer in observers.values { observer.yield(change) }
    }

    // MARK: - Requests

    /// Sends a request and returns the host's reply, throwing when the host
    /// declines it. A `key` makes repeating the same change safe: the host
    /// performs it once and answers a repeat with the first success.
    public func request(_ request: HostRequest, key: UUID? = nil) async throws -> HostReply {
        guard let connection, isConnected else { throw HostClientError.notConnected }
        let update = OptimisticTaskUpdate(request)
        if let update { taskUpdates.append(update) }
        defer {
            if let update { taskUpdates.removeAll { $0.id == update.id } }
        }
        let reply = try await connection.request(request, key: key)
        switch reply {
        case .failed(let message): throw HostClientError.rejected(message)
        case .unknown: throw HostClientError.unexpectedReply
        default: return reply
        }
    }

    /// Sends a request whose only result is success, reporting failures as `actionError`.
    public func send(_ request: HostRequest) {
        Task { await perform(request) }
    }

    @discardableResult
    public func perform(_ request: HostRequest) async -> HostReply? {
        do {
            return try await self.request(request)
        } catch is CancellationError {
            return nil
        } catch HostClientError.notConnected where request.isAutomatic {
            return nil
        } catch HostClientError.disconnected where request.isAutomatic {
            return nil
        } catch {
            actionError = error.localizedDescription
            return nil
        }
    }

    public func git(_ operation: GitOperation, in repository: URL, workspace workspaceID: UUID) async throws -> GitReply {
        guard case .git(let reply) = try await request(.git(workspaceID: workspaceID, repository: repository, operation: operation)) else {
            throw HostClientError.unexpectedReply
        }
        return reply
    }

    public func files(_ request: FileRequest, in workspaceID: UUID) async throws -> FileReply {
        guard case .files(let reply) = try await self.request(.files(workspaceID: workspaceID, request: request)) else {
            throw HostClientError.unexpectedReply
        }
        return reply
    }

    // MARK: - Lookup

    public func workspace(_ id: UUID?) -> WireWorkspace? {
        tasks?.workspaces.first { $0.id == id }
    }

    public func task(_ id: String) -> WireTask? {
        tasks?.tasks.first { $0.id == id }
    }

    /// The models a provider's tasks can switch to, as the host lists them.
    public func models(for provider: AgentProvider) -> [AgentModel] {
        tasks?.providers.first { $0.provider == provider }?.models ?? []
    }

    public var enabledProviders: [AgentProvider] {
        tasks?.providers.filter(\.isEnabled).map(\.provider) ?? []
    }

    /// A path on the host, abbreviated against its home folder for display.
    public func displayPath(_ path: String) -> String {
        guard let home = hello?.homeDirectory, path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// A custom project icon, fetched once and cached for the session.
    public func icon(forKey key: String) async -> Data? {
        if let data = icons[key] { return data }
        guard case .icon(let data) = try? await request(.icon(key: key)) else { return nil }
        icons[key] = data
        return data
    }

    // MARK: - Events

    private func apply(_ event: HostEvent) {
        switch event {
        case .hello(let hello):
            self.hello = hello
        case .tasks(let snapshot):
            let previous = hostTasks
            hostTasks = snapshot
            tasksDidChange(from: previous)
            connections?.delegate?.hostDidLoadTasks(self)
        case .tasksChanged(let delta):
            guard var snapshot = hostTasks else { return }
            let previous = snapshot
            snapshot.apply(delta)
            hostTasks = snapshot
            tasksDidChange(from: previous)
        case .transcript(let taskID, let messages):
            transcriptErrors[taskID] = nil
            conversations.transcripts[taskID] = messages
            reconcilePendingPrompts(for: taskID)
        case .transcriptChanged(let taskID, let delta):
            conversations.transcripts[taskID, default: []].apply(delta)
            reconcilePendingPrompts(for: taskID)
        case .transcriptUnavailable(let taskID, let message):
            transcriptErrors[taskID] = message
        case .git(let scope, let repositories):
            gitStatuses[scope] = repositories
        case .commands(let workspaceID, let commands):
            self.commands[workspaceID] = commands
        case .directory(let workspaceID, let path, let entries):
            directories[.directory(workspaceID: workspaceID, path: path)] = entries
        case .fileChanged(let workspaceID, let path):
            fileRevisions[.file(workspaceID: workspaceID, path: path), default: 0] += 1
        case .remoteAccess(let remoteAccess):
            self.remoteAccess = remoteAccess
        case .unknown:
            break
        }
        notify(.event(event))
    }

    private func tasksDidChange(from previous: WireTasksSnapshot?) {
        dropListedDrafts()
        for taskID in Set(conversations.tasksAwaitingAgent.keys).union(conversations.pendingPrompts.keys) {
            if let status = task(taskID)?.status {
                let previousStatus = previous?.tasks.first { $0.id == taskID }?.status
                conversations.noteStatus(status, previous: previousStatus, for: taskID)
            } else if draftTask(taskID) == nil {
                conversations.tasksAwaitingAgent[taskID] = nil
            }
        }
    }

    private func reconcilePendingPrompts(for taskID: String) {
        for confirmation in conversations.reconcile(taskID: taskID) {
            onPendingPromptShown?(confirmation.promptID, confirmation.messageID)
        }
    }
}

/// Something that happened to a host's connection, as `HostClient.changes()` reports it.
public nonisolated enum HostClientChange: Sendable {
    case state(HostClient.State)
    case event(HostEvent)
    /// The host no longer accepts this device, which has forgotten it.
    case revoked(String)
}

private extension HostRequest {
    /// Connection and view bookkeeping can race suspension or route changes.
    /// Losing that connection isn't a failed user action.
    var isAutomatic: Bool {
        switch self {
        case .activity, .registerPush, .subscribe, .unsubscribe, .task(_, .viewed): true
        default: false
        }
    }
}

public extension Task where Success == Never, Failure == Never {
    /// Suspends until the calling task is cancelled.
    static func waitUntilCancelled() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(86_400))
        }
    }
}

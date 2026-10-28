import Foundation
import Observation
import OSLog

/// One host as a client sees it: the connection, and the state it mirrors.
///
/// Views declare what they need with `follow(_:)`; the client subscribes while
/// any view follows a topic and resubscribes after reconnecting, so screens
/// never manage the connection themselves. A host that can't be reached keeps
/// showing what was last received. Requests are async and resolve with the
/// host's reply.
@MainActor
@Observable
final class HostClient: Identifiable {
    enum State: Equatable {
        case connecting
        case connected
        case offline(String)
    }

    /// How a paired host is reached.
    enum Route {
        case localNetwork
        case relay
    }

    enum Authentication {
        /// The Mac's own host, in process.
        case none
        case pair(secret: String)
        case token(String)
    }

    let id: String
    /// Whether this is the host running in this app, which alone can change
    /// files and projects and show terminals.
    let isLocal: Bool
    private(set) var pairedHost: PairedHost?
    private(set) var state: State = .connecting
    /// How the connection in use reaches a paired host.
    private(set) var route: Route?
    private(set) var hello: HostHello?
    /// The latest failed action, shown as an alert.
    var actionError: String?

    private var hostTasks: WireTasksSnapshot?
    private var taskUpdates: [OptimisticTaskUpdate] = []
    /// The host's tasks, projects and agents, with actions this client sent
    /// shown before the host confirms them.
    var tasks: WireTasksSnapshot? {
        guard var snapshot = hostTasks else { return nil }
        for update in taskUpdates { update.apply(to: &snapshot) }
        return snapshot
    }
    private(set) var gitStatuses: [GitScope: [GitRepositoryStatus]] = [:]
    private(set) var commands: [UUID: [WireCommand]] = [:]
    /// Entries of followed folders, by their `.directory` topic.
    private(set) var directories: [HostTopic: [FileEntry]] = [:]
    /// The host's remote access, while its own Mac UI follows it.
    private(set) var remoteAccess: WireRemoteAccess?
    /// Bumped each time a followed file changes on the host, by its `.file` topic.
    private(set) var fileRevisions: [HostTopic: Int] = [:]
    let conversations = ConversationStore()
    /// Why a followed conversation couldn't be loaded, by task.
    private(set) var transcriptErrors: [String: String] = [:]
    /// New tasks opened on this device, by draft ID. One stays after its first
    /// prompt until the task list shows the task the host created for it.
    var drafts: [String: TaskDraft] = [:]

    /// Called as the transcript takes over showing a prompt sent from this
    /// device, with the message that now shows it, so a send animation still
    /// running carries on in that message's row.
    @ObservationIgnored var onPendingPromptShown: ((PendingPrompt.ID, TranscriptMessage.ID) -> Void)?
    @ObservationIgnored weak var directory: HostDirectory?

    /// Connects to the Mac's own host; nil for a paired host.
    @ObservationIgnored private let loopback: (@MainActor () -> any HostConnection)?
    @ObservationIgnored private var connectingRoute: Route?
    /// Set after the local network failed, until the host is found there again.
    @ObservationIgnored private var skipsLocalNetwork = false
    @ObservationIgnored private var authentication: Authentication
    @ObservationIgnored private var connection: (any HostConnection)?
    @ObservationIgnored private var activity = ClientActivity(isActive: false, taskID: nil)
    /// How many views follow each topic. Every client always follows a host's tasks.
    @ObservationIgnored private var topicCounts: [HostTopic: Int] = [.tasks: 1]
    @ObservationIgnored private var icons: [String: Data] = [:]
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var failedAttempts = 0
    @ObservationIgnored private let localName: String

    private static let log = Logger(subsystem: "com.SilverMarcs.Atrium", category: "HostClient")

    /// The Mac's own host.
    init(localID: String, name: String, connection: @escaping @MainActor () -> any HostConnection) {
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

    var name: String { pairedHost?.displayName ?? hello?.hostName ?? localName }
    var isConnected: Bool { state == .connected }
    var isPairing: Bool { if case .pair = authentication { true } else { false } }
    /// Whether the host speaks a newer protocol than this app.
    var needsAppUpdate: Bool { (hello?.protocolVersion ?? 0) > HostProtocol.version }

    // MARK: - Connection

    func start() {
        connect()
    }

    /// Tries the host again now instead of waiting out the retry delay.
    func retryNow() {
        guard !isConnected else { return }
        reconnectTask?.cancel()
        reconnectTask = nil
        failedAttempts = 0
        connect()
    }

    func stop() {
        reconnectTask?.cancel()
        reconnectTask = nil
        connection?.close()
        connection = nil
        route = nil
    }

    func rename(to name: String?) {
        guard var host = pairedHost else { return }
        host.customName = name
        pairedHost = host
    }

    /// The host's own Mac connects in process; a paired host directly when
    /// it's on the local network, else through the relay.
    private func makeConnection() -> any HostConnection {
        if let loopback {
            connectingRoute = nil
            return loopback()
        }
        guard let pairedHost else { preconditionFailure("A remote host is always paired") }
        if !skipsLocalNetwork, let endpoint = directory?.localEndpoint(for: id) {
            connectingRoute = .localNetwork
            return RemoteHostConnection(host: pairedHost, over: FramedChannel(endpoint: endpoint))
        }
        connectingRoute = .relay
        return RemoteHostConnection(host: pairedHost, over: RelayClientChannel(hostID: id))
    }

    /// The host appeared on or left the local network. A connection through the
    /// relay moves to the local network as soon as the host is found there.
    func localNetworkChanged() {
        skipsLocalNetwork = false
        guard !isLocal, !isPairing, directory?.localEndpoint(for: id) != nil, route != .localNetwork else { return }
        stop()
        connect()
    }

    private func connect() {
        guard connection == nil, reconnectTask == nil else { return }
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
                guard case .paired(let token) = try await authenticating.request(.pair(secret: secret, device: HostCredentials.device)) else {
                    throw HostClientError.unexpectedReply
                }
                if let pairedHost { HostCredentials.save(pairedHost, token: token) }
                authentication = .token(token)
                directory?.didPair(self)
            case .token(let token):
                let reply = try await authenticating.request(.authenticate(token: token, deviceID: HostCredentials.device.id))
                if case .failed(let message) = reply { throw HostClientError.rejected(message) }
            }
            guard connection === authenticating else { return }
            Self.log.info("Connected to \(self.name, privacy: .public)")
            route = connectingRoute
            state = .connected
            failedAttempts = 0
            if activity.isActive || activity.taskID != nil { send(.activity(activity)) }
            if !isLocal, let push = directory?.pushRegistration { send(.registerPush(push)) }
            for topic in topicCounts.keys { subscribe(topic) }
            // Found nearby while connecting through the relay, as during pairing.
            if route == .relay, !skipsLocalNetwork, directory?.localEndpoint(for: id) != nil { localNetworkChanged() }
        } catch {
            guard connection === authenticating else { return }
            switch (authentication, error) {
            case (.pair, _):
                stop()
                directory?.pairingFailed(self, message: error.localizedDescription)
            case (.token, HostClientError.rejected(let message)):
                // The host revoked this device; staying paired would retry forever.
                stop()
                state = .offline(message)
                directory?.forget(self, reason: message)
            default:
                connectionDidClose(error.localizedDescription)
            }
        }
    }

    private func connectionDidClose(_ reason: String?) {
        connection = nil
        route = nil
        let reason = reason ?? HostClientError.disconnected.localizedDescription
        Self.log.info("Lost \(self.name, privacy: .public): \(reason, privacy: .public)")
        // A host found on the local network but not reachable there is tried
        // through the relay straight away.
        if connectingRoute == .localNetwork {
            skipsLocalNetwork = true
            connect()
            return
        }
        if isPairing {
            directory?.pairingFailed(self, message: reason)
            return
        }
        state = .offline(reason)
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

    /// Tells the host whether this client is in use and which of its tasks it shows.
    func setActivity(_ activity: ClientActivity) {
        guard activity != self.activity else { return }
        self.activity = activity
        if isConnected { send(.activity(activity)) }
    }

    // MARK: - Topics

    /// Keeps `topic` subscribed until the calling task is cancelled. Call from `.task`.
    func follow(_ topic: HostTopic) async {
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
    func reload(_ topic: HostTopic) {
        if case .transcript(let taskID) = topic { transcriptErrors[taskID] = nil }
        if isConnected { subscribe(topic) }
    }

    private func subscribe(_ topic: HostTopic) {
        Task { try? await request(.subscribe(topic)) }
    }

    // MARK: - Requests

    func request(_ request: HostRequest) async throws -> HostReply {
        guard let connection, isConnected else { throw HostClientError.notConnected }
        let update = OptimisticTaskUpdate(request)
        if let update { taskUpdates.append(update) }
        defer {
            if let update { taskUpdates.removeAll { $0.id == update.id } }
        }
        let reply = try await connection.request(request)
        switch reply {
        case .failed(let message): throw HostClientError.rejected(message)
        case .unknown: throw HostClientError.unexpectedReply
        default: return reply
        }
    }

    /// Sends a request whose only result is success, reporting failures as `actionError`.
    func send(_ request: HostRequest) {
        Task { await perform(request) }
    }

    @discardableResult
    func perform(_ request: HostRequest) async -> HostReply? {
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

    func git(_ operation: GitOperation, in repository: URL, workspace workspaceID: UUID) async throws -> GitReply {
        guard case .git(let reply) = try await request(.git(workspaceID: workspaceID, repository: repository, operation: operation)) else {
            throw HostClientError.unexpectedReply
        }
        return reply
    }

    func files(_ request: FileRequest, in workspaceID: UUID) async throws -> FileReply {
        guard case .files(let reply) = try await self.request(.files(workspaceID: workspaceID, request: request)) else {
            throw HostClientError.unexpectedReply
        }
        return reply
    }

    // MARK: - Lookup

    func workspace(_ id: UUID?) -> WireWorkspace? {
        tasks?.workspaces.first { $0.id == id }
    }

    func task(_ id: String) -> WireTask? {
        tasks?.tasks.first { $0.id == id }
    }

    /// The models a provider's tasks can switch to, as the host lists them.
    func models(for provider: AgentProvider) -> [AgentModel] {
        tasks?.providers.first { $0.provider == provider }?.models ?? []
    }

    /// A path on the host, abbreviated against its home folder for display.
    func displayPath(_ path: String) -> String {
        guard let home = hello?.homeDirectory, path.hasPrefix(home) else { return path }
        return "~" + path.dropFirst(home.count)
    }

    /// A custom project icon, fetched once and cached for the session.
    func icon(forKey key: String) async -> Data? {
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
            hostTasks = snapshot
            tasksDidChange()
            directory?.tasksDidLoad(on: self)
        case .tasksChanged(let delta):
            guard var snapshot = hostTasks else { return }
            snapshot.apply(delta)
            hostTasks = snapshot
            tasksDidChange()
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
    }

    private func tasksDidChange() {
        dropListedDrafts()
        for taskID in Set(conversations.tasksAwaitingAgent.keys).union(conversations.pendingPrompts.keys) {
            if let status = task(taskID)?.status {
                conversations.noteStatus(status, for: taskID)
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

extension Task where Success == Never, Failure == Never {
    /// Suspends until the calling task is cancelled.
    static func waitUntilCancelled() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(86_400))
        }
    }
}

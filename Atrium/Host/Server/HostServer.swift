import Foundation
import Observation
import SystemConfiguration

/// The host: the only part of Atrium that touches projects, Git, the file
/// system and agent integrations.
///
/// Every client, the Mac's own UI included, sees it through a connection:
/// requests come in, events go out for the topics each client follows. The
/// Mac's UI connects in process; with remote access on, other devices connect
/// through the relay end-to-end encrypted, authenticated against paired
/// devices. Feeds behind each topic run only while someone follows it. When a
/// task finishes or needs input, alerts follow the device currently in use.
@MainActor
@Observable
final class HostServer {
    enum Status: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    /// The relay connection, while remote access is on.
    private(set) var status: Status = .stopped
    private(set) var connectedDevices: [ClientDevice] = []
    private let pairing = Pairing()

    /// Reachable through the relay from any network. Keeps the Mac awake while on.
    var isRemoteAccessEnabled: Bool {
        didSet {
            guard isRemoteAccessEnabled != oldValue else { return }
            UserDefaults.standard.set(isRemoteAccessEnabled, forKey: Self.remoteAccessKey)
            isRemoteAccessEnabled ? startRemoteAccess() : stopRemoteAccess()
        }
    }

    /// What the pairing QR code and link carry.
    private var pairingLink: PairingLink {
        PairingLink(hostID: HostIdentity.hostID, publicKey: HostIdentity.publicKey, secret: pairing.secret, hostName: Self.hostName)
    }

    let hello = HostHello(
        hostID: HostIdentity.hostID,
        hostName: HostServer.hostName,
        protocolVersion: HostProtocol.version,
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
    )

    /// Remote access as the host's own Mac UI sees it.
    var remoteAccess: WireRemoteAccess {
        let connected = Set(connectedDevices.map(\.id))
        let relayStatus: WireRemoteAccess.Status = switch status {
        case .stopped: .off
        case .starting: .starting
        case .running: .connected
        case .failed(let message): .failed(message)
        }
        return WireRemoteAccess(
            isEnabled: isRemoteAccessEnabled,
            status: relayStatus,
            pairingLink: isRemoteAccessEnabled ? pairingLink.url : nil,
            devices: pairing.devices.map {
                WirePairedDevice(id: $0.id, name: $0.name, isConnected: connected.contains($0.id), lastConnectedAt: $0.lastConnectedAt)
            }
        )
    }

    /// Task terminals, which only this Mac's own UI shows.
    var terminals: HostTerminals { HostTerminals(sessions: sessions, workspaces: workspaces) }

    @ObservationIgnored private let integrations: AgentIntegrationStore
    @ObservationIgnored private let workspaces: WorkspaceStore
    @ObservationIgnored private let sessions: TaskSessionController
    @ObservationIgnored private let tasksFeed: TasksFeed
    @ObservationIgnored private var feeds: [HostTopic: any TopicFeed] = [:]
    @ObservationIgnored private var connections: [UUID: ServerConnection] = [:]
    @ObservationIgnored private var latestTasks: WireTasksSnapshot?
    @ObservationIgnored private var listener: RelayListener?
    @ObservationIgnored private let localListener = LocalListener()
    @ObservationIgnored private var awakeActivity: (any NSObjectProtocol)?

    private static let remoteAccessKey = "companion.enabled"
    /// Unauthenticated connections are dropped after this long.
    private static let authenticationTimeout: Duration = .seconds(30)

    static let hostName: String = {
        guard let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty else { return "Mac" }
        return name
    }()

    init() {
        workspaces = WorkspaceStore()
        integrations = AgentIntegrationStore(adapters: [CodexAgentAdapter(), ClaudeAgentAdapter()])
        sessions = TaskSessionController(integrations: integrations, workspaces: workspaces)
        tasksFeed = TasksFeed(integrations: integrations, sessions: sessions, workspaces: workspaces)
        isRemoteAccessEnabled = UserDefaults.standard.bool(forKey: Self.remoteAccessKey)
        feeds[.tasks] = tasksFeed
        tasksFeed.start { [weak self] event in self?.publishTasks(event) }
        Task { await integrations.refresh() }
        if isRemoteAccessEnabled { startRemoteAccess() }
    }

    // MARK: - Connections

    /// Connects this Mac's own UI, delivering events straight to it.
    func connectLocally(onEvent: @escaping (HostEvent) -> Void) -> ServerConnection {
        let connection = ServerConnection(isLocal: true, send: onEvent)
        connections[connection.id] = connection
        connection.sendHello(hello)
        return connection
    }

    func disconnect(_ connection: ServerConnection) {
        NotificationRouting.shared.remove(connectionID: connection.id)
        connections[connection.id] = nil
        pruneFeeds()
        updateConnectedDevices()
    }

    /// Revokes a device and disconnects it if it's online.
    private func forgetDevice(_ id: UUID) {
        guard let device = pairing.devices.first(where: { $0.id == id }) else { return }
        pairing.remove(device)
        for connection in connections.values where connection.device?.id == id {
            connection.close()
        }
    }

    private func accept(_ channel: any HostChannel) {
        // The connection owns its channel; the channel only refers back weakly.
        let connection = ServerConnection(isLocal: false, send: { event in
            guard let data = try? HostCodec.encode(ServerFrame.event(event)) else { return }
            channel.send(data)
        }, close: { channel.close() })
        connections[connection.id] = connection
        channel.onReady = { [weak connection, hello] in connection?.sendHello(hello) }
        channel.onMessage = { [weak self, weak channel, weak connection] data in
            guard let self, let channel, let connection else { return }
            guard let frame = try? HostCodec.decode(ClientFrame.self, from: data) else {
                channel.close()
                return
            }
            Task {
                let reply = await self.handle(frame.request, from: connection)
                guard let data = try? HostCodec.encode(ServerFrame.reply(id: frame.id, reply: reply)) else { return }
                channel.send(data)
            }
        }
        channel.onClose = { [weak self, weak connection] _ in
            guard let self, let connection else { return }
            self.disconnect(connection)
        }
        channel.start()
        Task { [weak self, weak connection] in
            try? await Task.sleep(for: Self.authenticationTimeout)
            guard let connection, !connection.isAuthenticated, self != nil else { return }
            connection.close()
        }
    }

    private func authenticate(_ connection: ServerConnection, as device: ClientDevice) {
        // A device that reconnects after its socket dropped replaces the stale connection.
        for other in connections.values where other !== connection && other.device?.id == device.id {
            NotificationRouting.shared.remove(connectionID: other.id)
            other.close()
        }
        connection.authenticated(as: device)
        updateConnectedDevices()
    }

    private func updateConnectedDevices() {
        var seen = Set<UUID>()
        connectedDevices = connections.values.compactMap(\.device).filter { seen.insert($0.id).inserted }
    }

    // MARK: - Requests

    func handle(_ request: HostRequest, from connection: ServerConnection) async -> HostReply {
        switch request {
        case .pair(let secret, let device):
            guard let token = pairing.pair(secret: secret, device: device) else {
                return .failed(message: "That pairing link has expired. Use the current one from Atrium Settings on \(Self.hostName).")
            }
            authenticate(connection, as: device)
            return .paired(token: token)
        case .authenticate(let token, let deviceID):
            guard let paired = pairing.authenticate(token: token, deviceID: deviceID) else {
                return .failed(message: "This device is no longer paired with \(Self.hostName). Pair it again from Atrium Settings there.")
            }
            authenticate(connection, as: ClientDevice(id: paired.id, name: paired.name))
            return .done
        default:
            guard connection.isAuthenticated else { return .failed(message: "Pair with this host first.") }
            // Any request from a device in the foreground means it's in use.
            if !connection.isLocal { NotificationRouting.shared.used(connectionID: connection.id) }
            return await handleAuthenticated(request, from: connection)
        }
    }

    private func handleAuthenticated(_ request: HostRequest, from connection: ServerConnection) async -> HostReply {
        let tasks = TaskService(integrations: integrations, sessions: sessions, workspaces: workspaces)
        switch request {
        case .pair, .authenticate:
            return .done
        case .unsupported:
            return .unsupported
        case .activity(let activity):
            if connection.isLocal {
                NotificationRouting.shared.macTaskID = activity.taskID
                integrations.setViewedThread(activity.isActive ? activity.taskID : nil)
            } else if let device = connection.device {
                NotificationRouting.shared.update(activity, deviceID: device.id, connectionID: connection.id)
            }
            return .done
        case .registerPush(let registration):
            if let id = connection.device?.id { pairing.registerPush(registration, forDevice: id) }
            return .done
        case .subscribe(.unknown):
            return .unsupported
        case .subscribe(.remoteAccess) where !connection.isLocal:
            return .hostOnly
        case .subscribe(let topic):
            guard let feed = feed(for: topic) else { return .failed(message: "That’s no longer available on this host.") }
            connection.subscribe(topic)
            if let current = feed.current { connection.deliver(current, for: topic) }
            feed.refresh()
            return .done
        case .unsubscribe(let topic):
            connection.unsubscribe(topic)
            pruneFeeds()
            return .done
        case .icon(let key):
            guard let url = workspaces.workspaces.first(where: { $0.customIconFilename == key })?.customIconURL,
                  let data = try? Data(contentsOf: url) else {
                return .failed(message: "That icon is no longer available.")
            }
            return .icon(data: data)
        case .refreshTasks:
            await integrations.refresh()
            return .done
        case .task(let id, let action):
            let reply = await tasks.perform(action, onTask: id)
            // Reconcile optimistic client actions before acknowledging them.
            publishTasks(.tasks(tasksFeed.snapshot()))
            if case .rewind = action { feeds[.transcript(taskID: id)]?.refresh() }
            return reply
        case .compose(let provider, let workspaceID, let settings):
            return await tasks.compose(provider: provider, workspaceID: workspaceID, settings: settings)
        case .prompt(let taskID, let text, let images):
            let reply = await tasks.prompt(text, images: images, toTask: taskID)
            publishTasks(.tasks(tasksFeed.snapshot()))
            feeds[.transcript(taskID: taskID)]?.refresh()
            return reply
        case .interrupt(let taskID):
            return await tasks.interrupt(task: taskID)
        case .addWorkspace(let path):
            guard connection.isLocal else { return .hostOnly }
            return WorkspaceService(workspaces: workspaces).add(path: path)
        case .workspace(let id, let action):
            guard let workspace = workspace(id) else { return .missingProject }
            return WorkspaceService(workspaces: workspaces).perform(action, on: workspace, isLocal: connection.isLocal)
        case .command(let workspaceID, let commandID, let action):
            guard let workspace = workspace(workspaceID),
                  let command = workspace.commands.first(where: { $0.id == commandID }) else {
                return .failed(message: "That command is no longer available.")
            }
            return WorkspaceService(workspaces: workspaces).perform(action, on: command, in: workspace)
        case .git(let workspaceID, let repository, let operation):
            guard let workspace = workspace(workspaceID) else { return .missingProject }
            let reply = await GitService.handle(operation, in: repository, workspace: workspace)
            // Clients see the new status before the reply, so they act on it.
            if operation.changesStatus { await refreshGit(of: workspaceID) }
            return reply
        case .files(let workspaceID, let request):
            guard let workspace = workspace(workspaceID) else { return .missingProject }
            return await FileService.handle(request, in: workspace, isLocal: connection.isLocal)
        case .setProviderEnabled(let provider, let isEnabled):
            guard connection.isLocal else { return .hostOnly }
            integrations[isEnabled: provider] = isEnabled
            Task { await integrations.refresh() }
            return .done
        case .setRemoteAccess(let isEnabled):
            guard connection.isLocal else { return .hostOnly }
            isRemoteAccessEnabled = isEnabled
            return .done
        case .forgetDevice(let id):
            guard connection.isLocal else { return .hostOnly }
            forgetDevice(id)
            return .done
        }
    }

    private func workspace(_ id: UUID) -> Workspace? {
        workspaces.workspaces.first { $0.id == id }
    }

    // MARK: - Feeds

    private func feed(for topic: HostTopic) -> (any TopicFeed)? {
        if let feed = feeds[topic] { return feed }
        let feed: any TopicFeed
        switch topic {
        case .unknown:
            return nil
        case .tasks:
            return tasksFeed
        case .remoteAccess:
            feed = RemoteAccessFeed(server: self)
        case .transcript(let taskID):
            guard integrations.threads.contains(where: { $0.id == taskID }) else { return nil }
            feed = TranscriptFeed(taskID: taskID, integrations: integrations)
        case .git(let scope):
            guard let workspace = workspace(scope.workspaceID) else { return nil }
            feed = GitFeed(scope: scope, workspace: workspace)
        case .commands(let workspaceID):
            guard let workspace = workspace(workspaceID) else { return nil }
            feed = CommandsFeed(workspace: workspace)
        case .directory(let workspaceID, let path):
            guard let workspace = workspace(workspaceID), WorkspaceAccess(directory: workspace.directory).allows(path) else { return nil }
            feed = DirectoryFeed(workspaceID: workspaceID, path: path)
        case .file(let workspaceID, let path):
            guard let workspace = workspace(workspaceID), WorkspaceAccess(directory: workspace.directory).allows(path) else { return nil }
            feed = FileFeed(workspaceID: workspaceID, path: path)
        }
        feeds[topic] = feed
        feed.start { [weak self] event in self?.publish(event, to: topic) }
        return feed
    }

    private func publish(_ event: HostEvent, to topic: HostTopic) {
        for connection in connections.values {
            connection.deliver(event, for: topic)
        }
    }

    private func publishTasks(_ event: HostEvent) {
        if case .tasks(let snapshot) = event {
            if let latestTasks {
                for task in snapshot.tasksNeedingAttention(since: latestTasks) { alertPhones(about: task) }
            }
            latestTasks = snapshot
        }
        publish(event, to: .tasks)
    }

    /// Stops feeds nobody follows anymore.
    private func pruneFeeds() {
        let followed = connections.values.filter(\.isAuthenticated).reduce(into: Set<HostTopic>()) { $0.formUnion($1.topics) }
        for (topic, feed) in feeds where topic != .tasks && !followed.contains(topic) {
            feed.stop()
            feeds[topic] = nil
        }
    }

    private func refreshGit(of workspaceID: UUID) async {
        let gitFeeds = feeds.values.compactMap { $0 as? GitFeed }.filter { $0.scope.workspaceID == workspaceID }
        for feed in gitFeeds { await feed.update() }
    }

    // MARK: - Remote access

    /// Opens the host to paired devices: on the local network, and through
    /// the relay from anywhere.
    private func startRemoteAccess() {
        // Development builds must not compete with the installed app's remote
        // access, unless they're pointed at their own relay.
        #if DEBUG
        guard ProcessInfo.processInfo.environment["ATRIUM_RELAY_URL"] != nil else { return }
        #endif
        guard listener == nil else { return }
        let listener = RelayListener()
        listener.onStateChange = { [weak self] state in
            switch state {
            case .starting: self?.status = .starting
            case .ready: self?.status = .running
            case .failed(let message): self?.status = .failed(message)
            }
        }
        listener.onChannel = { [weak self] channel in self?.accept(channel) }
        listener.onPushTokenUnregistered = { [weak self] token in self?.pairing.removePushToken(token) }
        self.listener = listener
        listener.start()
        localListener.onChannel = { [weak self] channel in self?.accept(channel) }
        localListener.start(name: Self.hostName)
        #if DEBUG
        FileHandle.standardError.write(Data("Atrium pairing link: \(pairingLink.url?.absoluteString ?? "")\n".utf8))
        #endif
        // A sleeping Mac can't answer the relay.
        awakeActivity = ProcessInfo.processInfo.beginActivity(
            options: .idleSystemSleepDisabled, reason: "Atrium remote access is on"
        )
    }

    private func stopRemoteAccess() {
        listener?.stop()
        listener = nil
        localListener.stop()
        if let awakeActivity { ProcessInfo.processInfo.endActivity(awakeActivity) }
        awakeActivity = nil
        for connection in connections.values where !connection.isLocal {
            NotificationRouting.shared.remove(connectionID: connection.id)
            connection.close()
            connections[connection.id] = nil
        }
        pruneFeeds()
        updateConnectedDevices()
        status = .stopped
    }

    /// Routes alerts to the active device, or all devices when none is active.
    private func alertPhones(about task: WireTask) {
        guard let listener else { return }
        let workspace = workspaces.workspaces.first { $0.id == task.workspaceID }
        let icon = ProjectNotificationIcon.pngData(at: workspace?.customIconURL)
        for device in pairing.devices {
            guard let push = device.push,
                  NotificationRouting.shared.shouldNotify(device.id, taskID: task.id) else { continue }
            listener.push(RelayPushAlert(
                token: push.token,
                environment: push.environment,
                title: task.projectName,
                subtitle: task.title,
                body: task.status == .waiting ? "Needs your input" : "Done",
                taskID: task.id,
                projectIcon: icon
            ))
        }
    }
}

private extension HostReply {
    static let missingProject = HostReply.failed(message: "That project is no longer on this host.")
}

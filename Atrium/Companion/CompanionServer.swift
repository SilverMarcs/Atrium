import Foundation
import Observation
import SystemConfiguration

/// The Mac side of the iPhone companion.
///
/// Connects out to the relay, accepts the end-to-end encrypted channels phones
/// open through it, authenticates them against paired devices, answers requests
/// through the same stores and controllers the Mac UI uses, and streams the state
/// each companion subscribes to. Feeds for a project's Git status and commands
/// run only while someone watches them. When a task finishes or needs input,
/// alerts follow the device currently using Atrium.
@MainActor
@Observable
final class CompanionServer {
    enum Status: Equatable {
        case stopped
        case starting
        case running(String)
        case failed(String)
    }

    private(set) var status: Status = .stopped
    private(set) var connectedDevices: [CompanionDevice] = []
    let pairing = CompanionPairing()

    /// Reachable through the relay from any network. Keeps the Mac awake while on.
    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            isEnabled ? start() : stop()
        }
    }

    /// What the pairing QR code encodes.
    var pairingLink: CompanionPairingLink {
        CompanionPairingLink(
            macID: CompanionIdentity.macID,
            publicKey: CompanionIdentity.publicKey,
            secret: pairing.secret,
            hostName: hostName
        )
    }

    @ObservationIgnored private let workspaces: WorkspaceStore
    @ObservationIgnored private let tasks: CompanionTaskService
    @ObservationIgnored private let tasksFeed: CompanionTasksFeed
    @ObservationIgnored private var listener: RelayListener?
    @ObservationIgnored private var awakeActivity: (any NSObjectProtocol)?
    @ObservationIgnored private var connections: [ObjectIdentifier: CompanionConnection] = [:]
    @ObservationIgnored private var gitFeeds: [UUID: CompanionGitFeed] = [:]
    @ObservationIgnored private var commandFeeds: [UUID: CompanionCommandsFeed] = [:]
    @ObservationIgnored private var transcriptSubscriptions: [String: HostTranscriptSubscription] = [:]
    @ObservationIgnored private let integrations: AgentIntegrationStore
    @ObservationIgnored private var latestTasks: WireTasksSnapshot?

    private static let enabledKey = "companion.enabled"
    /// Unauthenticated connections are dropped after this long.
    private static let authenticationTimeout: Duration = .seconds(30)

    let hostName: String = {
        guard let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty else { return "Mac" }
        return name
    }()

    init(integrations: AgentIntegrationStore, sessions: TaskSessionController, workspaces: WorkspaceStore) {
        self.workspaces = workspaces
        self.integrations = integrations
        tasks = CompanionTaskService(integrations: integrations, sessions: sessions, workspaces: workspaces)
        tasksFeed = CompanionTasksFeed(integrations: integrations, sessions: sessions, workspaces: workspaces)
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        if isEnabled { start() }
    }

    func start() {
        // Development builds must not compete with the installed app's relay connection.
        #if !DEBUG
        guard listener == nil else { return }
        let listener = RelayListener()
        listener.onStateChange = { [weak self] state in
            switch state {
            case .starting: self?.status = .starting
            case .ready(let description): self?.status = .running(description)
            case .failed(let message): self?.status = .failed(message)
            }
        }
        listener.onChannel = { [weak self] channel in self?.accept(channel) }
        listener.onPushTokenUnregistered = { [weak self] token in self?.pairing.removePushToken(token) }
        self.listener = listener
        listener.start()
        tasksFeed.start { [weak self] snapshot in self?.broadcast(tasks: snapshot) }
        // A sleeping Mac can't answer the relay.
        awakeActivity = ProcessInfo.processInfo.beginActivity(
            options: .idleSystemSleepDisabled, reason: "The Atrium iPhone companion is on"
        )
        #endif
    }

    func stop() {
        listener?.stop()
        listener = nil
        if let awakeActivity { ProcessInfo.processInfo.endActivity(awakeActivity) }
        awakeActivity = nil
        tasksFeed.stop()
        latestTasks = nil
        for connection in connections.values {
            NotificationRouting.shared.remove(connectionID: connection.id)
            connection.close()
        }
        connections.removeAll()
        updateFeeds()
        connectedDevices = []
        status = .stopped
    }

    /// Revokes a device and disconnects it if it's online.
    func remove(_ device: CompanionPairedDevice) {
        pairing.remove(device)
        for connection in connections.values where connection.device?.id == device.id {
            connection.close()
        }
    }

    // MARK: - Connections

    private func accept(_ channel: any CompanionChannel) {
        let connection = CompanionConnection(channel: channel, server: self)
        connections[ObjectIdentifier(connection)] = connection
        connection.start(hostName: hostName) { [weak self] connection in
            self?.disconnect(connection)
        }
        Task { [weak self, weak connection] in
            try? await Task.sleep(for: Self.authenticationTimeout)
            guard let connection, !connection.isAuthenticated, self != nil else { return }
            connection.close()
        }
    }

    private func disconnect(_ connection: CompanionConnection) {
        NotificationRouting.shared.remove(connectionID: connection.id)
        connections.removeValue(forKey: ObjectIdentifier(connection))
        updateFeeds()
        updateConnectedDevices()
    }

    private func updateConnectedDevices() {
        var seen = Set<UUID>()
        connectedDevices = connections.values.compactMap(\.device).filter { seen.insert($0.id).inserted }
    }

    // MARK: - Requests

    func handle(_ request: CompanionRequest, from connection: CompanionConnection) async -> CompanionReply {
        switch request {
        case .pair(let secret, let device):
            guard let token = pairing.pair(secret: secret, device: device) else {
                return .failed(message: "That pairing QR code has expired. Scan the current one in Atrium Settings on your Mac.")
            }
            authenticate(connection, as: device)
            return .paired(token: token)
        case .authenticate(let token, let deviceID):
            guard let paired = pairing.authenticate(token: token, deviceID: deviceID) else {
                return .failed(message: "This iPhone is no longer paired. Pair it again from Atrium Settings on your Mac.")
            }
            authenticate(connection, as: CompanionDevice(id: paired.id, name: paired.name))
            return .done
        default:
            guard connection.isAuthenticated else {
                return .failed(message: "Pair with your Mac first.")
            }
            return await handleAuthenticated(request, from: connection)
        }
    }

    private func authenticate(_ connection: CompanionConnection, as device: CompanionDevice) {
        // A phone that reconnects after iOS dropped its socket replaces the stale connection.
        for other in connections.values where other !== connection && other.device?.id == device.id {
            NotificationRouting.shared.remove(connectionID: other.id)
            other.close()
        }
        connection.authenticated(as: device)
        updateConnectedDevices()
    }

    private func handleAuthenticated(_ request: CompanionRequest, from connection: CompanionConnection) async -> CompanionReply {
        // Any request from a companion in the foreground means it's in use.
        NotificationRouting.shared.used(connectionID: connection.id)
        switch request {
        case .pair, .authenticate:
            return .done
        case .activity(let activity):
            if let device = connection.device {
                NotificationRouting.shared.update(activity, deviceID: device.id, connectionID: connection.id)
            }
            return .done
        case .registerPush(let registration):
            if let id = connection.device?.id { pairing.registerPush(registration, forDevice: id) }
            return .done
        case .subscribe(let topic):
            guard isValid(topic) else { return .failed(message: "That project is no longer on your Mac.") }
            connection.subscribe(topic)
            updateFeeds()
            sendCurrentState(of: topic, to: connection)
            return .done
        case .unsubscribe(let topic):
            connection.unsubscribe(topic)
            updateFeeds()
            return .done
        case .icon(let key):
            guard let workspace = workspaces.workspaces.first(where: { $0.customIconFilename == key }),
                  let url = workspace.customIconURL,
                  let data = try? Data(contentsOf: url) else {
                return .failed(message: "That icon is no longer available.")
            }
            return .icon(data: data)
        case .refreshTasks:
            await tasks.integrations.refresh()
            return .done
        case .task(let id, let action):
            let reply = await tasks.perform(action, onTask: id)
            // Reconcile optimistic companion actions before acknowledging them.
            broadcast(tasks: tasksFeed.snapshot())
            return reply
        case .compose(let provider, let workspaceID, let settings):
            return await tasks.compose(provider: provider, workspaceID: workspaceID, settings: settings)
        case .prompt(let taskID, let text, let images):
            let reply = await tasks.prompt(text, images: images, toTask: taskID)
            broadcast(tasks: tasksFeed.snapshot())
            return reply
        case .interrupt(let taskID):
            return await tasks.interrupt(task: taskID)
        case .updateScratchpad(let workspaceID, let text):
            guard let workspace = workspace(workspaceID) else { return .failed(message: "That project is no longer on your Mac.") }
            workspace.scratchPad = text
            return .done
        case .git(let workspaceID, let action):
            guard let feed = gitFeed(for: workspaceID) else { return .failed(message: "That project is no longer on your Mac.") }
            do {
                try await feed.perform(action)
                return .done
            } catch {
                return .failed(message: error.localizedDescription)
            }
        case .gitDiff(let workspaceID, let path, let isStaged):
            guard let feed = gitFeed(for: workspaceID) else { return .failed(message: "That project is no longer on your Mac.") }
            do {
                return .diff(text: try await feed.diff(path: path, isStaged: isStaged))
            } catch {
                return .failed(message: error.localizedDescription)
            }
        case .command(let workspaceID, let commandID, let action):
            guard let command = workspace(workspaceID)?.commands.first(where: { $0.id == commandID }) else {
                return .failed(message: "That command is no longer available.")
            }
            switch action {
            case .run:
                if command.isRunning { command.restart() } else { command.workspace?.runCommand(command) }
            case .stop:
                command.stop()
            }
            return .done
        }
    }

    // MARK: - Feeds

    private func broadcast(tasks snapshot: WireTasksSnapshot) {
        if let latestTasks {
            for task in snapshot.tasksNeedingAttention(since: latestTasks) { alertPhones(about: task) }
        }
        latestTasks = snapshot
        for connection in connections.values where connection.isAuthenticated {
            connection.push(tasks: snapshot)
        }
    }

    /// Routes alerts to the active device, or all devices when none is active.
    private func alertPhones(about task: WireTask) {
        let workspace = workspaces.workspaces.first { $0.id == task.workspaceID }
        let icon = ProjectNotificationIcon.pngData(at: workspace?.customIconURL)
        for device in pairing.devices {
            guard let push = device.push,
                  NotificationRouting.shared.shouldNotify(device.id, taskID: task.id) else { continue }
            listener?.push(RelayPushAlert(
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

    private func sendCurrentState(of topic: CompanionTopic, to connection: CompanionConnection) {
        switch topic {
        case .tasks:
            connection.push(tasks: latestTasks ?? tasksFeed.snapshot())
        case .git(let workspaceID):
            if let status = gitFeeds[workspaceID]?.status {
                connection.push(.git(workspaceID: workspaceID, status: status))
            }
        case .commands(let workspaceID):
            if let commands = commandFeeds[workspaceID]?.commands {
                connection.push(.commands(workspaceID: workspaceID, commands: commands))
            }
        case .transcript(let taskID):
            if let messages = transcriptSubscriptions[taskID]?.feed.messages {
                connection.push(transcript: messages, of: taskID)
            }
        }
    }

    /// Starts feeds someone subscribed to and stops those nobody watches anymore.
    private func updateFeeds() {
        let topics = connections.values.filter(\.isAuthenticated).reduce(into: Set<CompanionTopic>()) { $0.formUnion($1.topics) }
        var gitIDs = Set<UUID>()
        var commandIDs = Set<UUID>()
        var transcriptIDs = Set<String>()
        for topic in topics {
            switch topic {
            case .tasks: break
            case .git(let id): gitIDs.insert(id)
            case .commands(let id): commandIDs.insert(id)
            case .transcript(let id): transcriptIDs.insert(id)
            }
        }

        for (id, subscription) in transcriptSubscriptions where !transcriptIDs.contains(id) {
            subscription.release()
            transcriptSubscriptions[id] = nil
        }
        for id in transcriptIDs where transcriptSubscriptions[id] == nil {
            transcriptSubscriptions[id] = integrations.acquireTranscriptFeed(taskID: id) { [weak self] messages in
                guard let self else { return }
                for connection in self.connections.values where connection.isAuthenticated {
                    connection.push(transcript: messages, of: id)
                }
            }
        }

        for (id, feed) in gitFeeds where !gitIDs.contains(id) {
            feed.stop()
            gitFeeds[id] = nil
        }
        for id in gitIDs where gitFeeds[id] == nil {
            guard let workspace = workspace(id) else { continue }
            let feed = CompanionGitFeed(workspace: workspace)
            feed.onChange = { [weak self] status in
                self?.publish(.git(workspaceID: id, status: status), to: .git(workspaceID: id))
            }
            gitFeeds[id] = feed
            feed.start()
        }

        for (id, feed) in commandFeeds where !commandIDs.contains(id) {
            feed.stop()
            commandFeeds[id] = nil
        }
        for id in commandIDs where commandFeeds[id] == nil {
            guard let workspace = workspace(id) else { continue }
            let feed = CompanionCommandsFeed(workspace: workspace)
            commandFeeds[id] = feed
            feed.start { [weak self] commands in
                self?.publish(.commands(workspaceID: id, commands: commands), to: .commands(workspaceID: id))
            }
        }
    }

    private func publish(_ event: CompanionEvent, to topic: CompanionTopic) {
        for connection in connections.values where connection.isAuthenticated && connection.topics.contains(topic) {
            connection.push(event)
        }
    }

    /// Git actions can arrive before a subscription; they still need a feed to act through.
    private func gitFeed(for workspaceID: UUID) -> CompanionGitFeed? {
        if let feed = gitFeeds[workspaceID] { return feed }
        return workspace(workspaceID).map(CompanionGitFeed.init)
    }

    private func isValid(_ topic: CompanionTopic) -> Bool {
        switch topic {
        case .tasks, .transcript: true
        case .git(let id), .commands(let id): workspace(id) != nil
        }
    }

    private func workspace(_ id: UUID) -> Workspace? {
        workspaces.workspaces.first { $0.id == id }
    }
}

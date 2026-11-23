import AtriumProtocol
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
/// devices. Agents use the host's tools over MCP: the agents this Mac runs on
/// its agent bridge, and paired agents such as ChatGPT through their gateway
/// and the relay, which may do nothing else. Feeds behind each topic run only while someone
/// follows it. When a task finishes or needs input, alerts follow the device
/// currently in use.
@MainActor
@Observable
public final class HostServer {
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
    private let ledger = RequestLedger()

    /// Reachable through the relay from any network. Keeps the Mac awake while on.
    var isRemoteAccessEnabled: Bool {
        didSet {
            guard isRemoteAccessEnabled != oldValue else { return }
            UserDefaults.standard.set(isRemoteAccessEnabled, forKey: Self.remoteAccessKey)
            isRemoteAccessEnabled ? startRemoteAccess() : stopRemoteAccess()
        }
    }

    /// The name the user chose for this host, or nil to use this Mac's computer name.
    private(set) var customHostName: String? {
        didSet {
            guard customHostName != oldValue else { return }
            UserDefaults.standard.set(customHostName, forKey: Self.customHostNameKey)
            hostIdentityDidChange()
            localListener.updateName(hostName)
        }
    }

    /// The icon this host advertises for itself.
    public private(set) var hostIcon: HostIcon {
        didSet {
            guard hostIcon != oldValue else { return }
            UserDefaults.standard.set(hostIcon.rawValue, forKey: Self.hostIconKey)
            hostIdentityDidChange()
        }
    }

    /// The name this host advertises to every client, itself included.
    public var hostName: String { customHostName ?? Self.defaultHostName }

    /// What the pairing QR code and link carry.
    private var pairingLink: PairingLink {
        PairingLink(
            hostID: HostIdentity.hostID,
            publicKey: HostIdentity.publicKey,
            secret: pairing.secret,
            hostName: hostName,
            hostIcon: hostIcon
        )
    }

    public var hello: HostHello {
        HostHello(
            hostID: HostIdentity.hostID,
            hostName: hostName,
            hostIcon: hostIcon,
            protocolVersion: HostProtocol.version,
            homeDirectory: homeDirectory
        )
    }

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
            },
            customHostName: customHostName,
            defaultHostName: Self.defaultHostName
        )
    }

    @ObservationIgnored private let integrations: AgentIntegrationStore
    @ObservationIgnored private let workspaces: WorkspaceStore
    @ObservationIgnored private let sessions: TaskSessionController
    @ObservationIgnored private let orchestrator: Orchestrator
    @ObservationIgnored private let queue: PromptQueue
    @ObservationIgnored private let tasks: TaskService
    @ObservationIgnored private let media: MediaService
    @ObservationIgnored private var isLoadingInitialTasks = true
    @ObservationIgnored private let secrets: SecretRequests
    /// What Settings → Integrations turns on, which stays with this Mac's host.
    @ObservationIgnored public let integrationSettings = IntegrationSettings()
    @ObservationIgnored private let antigravity: AntigravityAgentAdapter
    @ObservationIgnored private let tasksFeed: TasksFeed
    @ObservationIgnored private var feeds: [HostTopic: any TopicFeed] = [:]
    @ObservationIgnored private var connections: [UUID: ServerConnection] = [:]
    @ObservationIgnored private var latestTasks: WireTasksSnapshot?
    @ObservationIgnored private var listener: RelayListener?
    /// Phones pushed an alert since Atrium last came to the front anywhere.
    @ObservationIgnored private var alertedDevices: Set<UUID> = []
    @ObservationIgnored private let localListener = LocalListener()
    @ObservationIgnored private var awakeActivity: (any NSObjectProtocol)?
    @ObservationIgnored private let tools: ToolServer

    @ObservationIgnored private let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)

    private static let remoteAccessKey = "companion.enabled"
    private static let customHostNameKey = "host.name"
    private static let hostIconKey = "host.icon"
    /// Unauthenticated connections are dropped after this long.
    private static let authenticationTimeout: Duration = .seconds(30)

    static let defaultHostName: String = {
        guard let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty else { return "Mac" }
        return name
    }()

    public init() {
        let savedName = UserDefaults.standard.string(forKey: Self.customHostNameKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
        customHostName = savedName?.isEmpty == false ? savedName : nil
        hostIcon = UserDefaults.standard.string(forKey: Self.hostIconKey).flatMap(HostIcon.init(rawValue:)) ?? .default
        let store = WorkspaceStore()
        workspaces = store
        let bridge = AgentBridgeServer()
        let instructions = ChatInstructions(settings: integrationSettings)
        instructions.projectFolders = { directory in store.folders(forDirectory: directory) }
        let antigravity = AntigravityAgentAdapter(bridge: bridge, instructions: instructions)
        self.antigravity = antigravity
        integrations = AgentIntegrationStore(adapters: [
            CodexAgentAdapter(bridge: bridge, instructions: instructions), ClaudeAgentAdapter(bridge: bridge, instructions: instructions),
            antigravity,
        ], settings: integrationSettings)
        sessions = TaskSessionController(integrations: integrations)
        orchestrator = Orchestrator(integrations: integrations, directory: bridge.storage)
        queue = PromptQueue(integrations: integrations, file: bridge.storage.appending(path: "queued-prompts.json"))
        tasks = TaskService(integrations: integrations, sessions: sessions, workspaces: workspaces, queue: queue, orchestrator: orchestrator)
        media = MediaService(integrations: integrations)
        let pullRequests = PullRequestTracker(file: bridge.storage.appending(path: "pull-requests.json"))
        secrets = SecretRequests(integrations: integrations)
        tasksFeed = TasksFeed(
            integrations: integrations, sessions: sessions, workspaces: workspaces, orchestrator: orchestrator, queue: queue,
            pullRequests: pullRequests)
        tools = ToolServer(settings: integrationSettings) { [integrations, orchestrator] meta in
            guard let id = integrations.toolCaller(meta: meta) else { return nil }
            return await orchestrator.caller(for: id)
        }
        isRemoteAccessEnabled = UserDefaults.standard.bool(forKey: Self.remoteAccessKey)
        feeds[.tasks] = tasksFeed
        tasksFeed.start { [weak self] event in self?.publishTasks(event) }
        integrations.onStatusChange = { [orchestrator, queue] thread in
            orchestrator.observe(thread)
            queue.observe(thread)
        }
        queue.onSend = { [weak self] in
            guard let self else { return }
            publishTasks(.tasks(tasksFeed.snapshot()))
        }
        queue.deliver = { [weak self] entry, thread in
            guard let self else { return }
            let reply = await tasks.prompt(entry.text, images: entry.images, toTask: thread.id, from: entry.requester)
            if case .failed(let message) = reply { throw IntegrationError(message: message) }
            feeds[.transcript(taskID: thread.id)]?.refresh()
        }
        integrations.onAttention = { [weak self] thread in
            guard let self, let target = orchestrator.attentionTarget(for: thread) else { return }
            alertMac(about: target)
        }
        orchestrator.onSettleItself = { [weak self] thread in
            guard let self else { return }
            sessions.settle(thread)
            publishTasks(.tasks(tasksFeed.snapshot()))
        }
        integrations.onThreadRemoved = { [orchestrator, queue] id in
            orchestrator.sessionRemoved(id)
            queue.remove(id)
        }
        NotificationRouting.shared.onCameToFront = { [weak self] device in self?.clearAlerts(except: device) }
        tools.register(HostTools(
            integrations: integrations, secrets: secrets, snapshot: { [tasksFeed] in tasksFeed.snapshot() },
            defaultMode: { [integrationSettings] in integrationSettings.defaultPermissionMode },
            perform: { [weak self] request, actor in
                await self?.performTool(request, as: actor) ?? .failed(message: "This host has stopped.")
            },
            refreshTranscript: { [weak self] id in self?.feeds[.transcript(taskID: id)]?.refresh() }
        ).tools)
        bridge.onMCP = { [tools] body in await tools.handle(body, as: .localAgent) }
        // Agents still running from before a relaunch call the tools at the saved endpoint.
        Task { _ = try? await bridge.start() }
        Task { [weak self] in
            guard let self else { return }
            await integrations.refresh()
            isLoadingInitialTasks = false
            if connections.values.contains(where: { $0.topics.contains(.tasks) && $0.device?.kind != .agent }) {
                tasksFeed.refreshPullRequests()
            }
        }
        if isRemoteAccessEnabled { startRemoteAccess() }
    }

    /// The account and usage a provider reports, for Settings → Agents.
    public func usage(of provider: AgentProvider) async throws -> AgentUsageSnapshot {
        switch provider {
        case .codex:
            // A separate, short-lived connection keeps Settings independent of
            // enabled integrations and can't interrupt an active conversation.
            let reader = CodexAgentAdapter(bridge: AgentBridgeServer(), instructions: ChatInstructions())
            defer { reader.setEnabled(false) }
            return try await reader.usageSnapshot()
        case .claude:
            return try await ClaudeUsageReader.read()
        case .antigravity:
            // Through the adapter's live server.
            return try await antigravity.usageSnapshot()
        }
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
    func forgetDevice(_ id: UUID) {
        guard let device = pairing.devices.first(where: { $0.id == id }) else { return }
        pairing.remove(device)
        for connection in connections.values where connection.device?.id == id {
            connection.close()
        }
    }

    /// Pairs an agent's gateway the user approved on this Mac, such as
    /// ChatGPT's, turning remote access on for it to reach this host. It can
    /// only use the host's tools, as far as `access` lets it, and removing it
    /// in Settings revokes it.
    func pairAgent(named name: String, access: AgentAccess) -> (device: ClientDevice, token: String) {
        let device = ClientDevice(id: UUID(), name: name, kind: .agent)
        let token = pairing.pair(agent: device, access: access)
        isRemoteAccessEnabled = true
        return (device, token)
    }

    /// Takes a client's connection, which authenticates as a paired device.
    private func accept(_ channel: any HostChannel) {
        // The connection owns its channel; the channel only refers back weakly.
        let connection = ServerConnection(isLocal: false, send: { event in
            guard let data = try? HostCodec.encode(ServerFrame.event(event)) else { return }
            channel.send(data)
        }, close: { channel.close() })
        connections[connection.id] = connection
        channel.onReady = { [weak self, weak connection] in
            guard let self, let connection else { return }
            connection.sendHello(self.hello)
        }
        channel.onMessage = { [weak self, weak channel, weak connection] data in
            guard let self, let channel, let connection else { return }
            guard let frame = try? HostCodec.decode(ClientFrame.self, from: data) else {
                channel.close()
                return
            }
            Task {
                let reply = await self.handle(frame.request, from: connection, key: frame.key)
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
        // A device that reconnects after its socket dropped replaces the stale
        // connection, whose foreground presence would otherwise keep steering
        // alerts. Connections that never reported presence, such as several
        // calls from an agent's gateway at once, share their device.
        for other in connections.values where other !== connection && other.device?.id == device.id && other.reportsActivity {
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

    /// Broadcasts this host's updated name and icon to every connected client.
    private func hostIdentityDidChange() {
        let hello = self.hello
        for connection in connections.values where connection.isAuthenticated {
            connection.sendHello(hello)
        }
    }

    // MARK: - Requests

    /// Answers a client's request. One sent with a key is performed once per
    /// device; see `RequestLedger`.
    func handle(_ request: HostRequest, from connection: ServerConnection, key: UUID? = nil) async -> HostReply {
        switch request {
        case .pair(let secret, let device):
            guard let token = pairing.pair(secret: secret, device: device) else {
                return .failed(message: "That pairing link has expired. Use the current one from Atrium Settings on \(hostName).")
            }
            authenticate(connection, as: device)
            return .paired(token: token)
        case .authenticate(let token, let deviceID):
            guard let paired = pairing.authenticate(token: token, deviceID: deviceID) else {
                return .failed(message: "This device is no longer paired with \(hostName). Pair it again from Atrium Settings there.")
            }
            authenticate(connection, as: ClientDevice(id: paired.id, name: paired.name, kind: paired.kind ?? .app))
            return .done
        default:
            guard connection.isAuthenticated else { return .failed(message: "Pair with this host first.") }
            // An agent's gateway only uses the host's tools, which act for it.
            if connection.device?.kind == .agent {
                guard case .mcp = request else { return .failed(message: "This device can only use the host’s tools.") }
            }
            // Any request from a device in the foreground means it's in use.
            if !connection.isLocal { NotificationRouting.shared.used(connectionID: connection.id) }
            guard let key else { return await handleAuthenticated(request, from: connection) }
            let client = connection.device?.id.uuidString ?? "local"
            return await ledger.perform(key, for: client) { [weak self, connection] in
                await self?.handleAuthenticated(request, from: connection) ?? HostReply.failed(message: "This host has stopped.")
            }
        }
    }

    /// Performs a tool's request as the device that called the tool, for the
    /// session it calls from, the way a connected client's request would go.
    private func performTool(_ request: HostRequest, as actor: HostTools.Actor) async -> HostReply {
        let connection = ServerConnection(isLocal: false, send: { _ in })
        connection.authenticated(as: actor.device)
        connection.caller = actor.caller
        return await handleAuthenticated(request, from: connection)
    }

    private func handleAuthenticated(_ request: HostRequest, from connection: ServerConnection) async -> HostReply {
        switch request {
        case .pair, .authenticate:
            return .done
        case .mcp(let message):
            guard let device = connection.device, device.kind == .agent else { return .hostOnly }
            let access = pairing.devices.first { $0.id == device.id }?.access ?? .readOnly
            return .mcp(message: await tools.handle(message, as: .paired(device, access)) ?? Data())
        case .unsupported:
            return .unsupported
        case .activity(let activity):
            let wasInactive = connection.activity?.isActive == false
            connection.activity = activity
            if connection.isLocal {
                NotificationRouting.shared.macTaskID = activity.taskID
                integrations.setViewedThread(activity.isActive ? activity.taskID : nil)
            } else if let device = connection.device {
                NotificationRouting.shared.update(activity, deviceID: device.id, connectionID: connection.id)
            }
            if wasInactive, activity.isActive, let taskID = activity.taskID,
               connection.topics.contains(.transcript(taskID: taskID)) {
                tasksFeed.refreshPullRequests(taskID: taskID)
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
            switch topic {
            case .tasks where !isLoadingInitialTasks && connection.device?.kind != .agent:
                tasksFeed.refreshPullRequests()
            case .transcript(let taskID):
                tasksFeed.refreshPullRequests(taskID: taskID)
            default:
                break
            }
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
        case .page(let taskID, let key):
            return await media.page(key, inTask: taskID)
        case .image(let taskID, let path, let maxPixelSize, let pageKey):
            return await media.image(path, maxPixelSize: maxPixelSize, inTask: taskID, pageKey: pageKey)
        case .promptImage(let taskID, let messageID, let index, let maxPixelSize):
            return await media.promptImage(index, of: messageID, maxPixelSize: maxPixelSize, inTask: taskID)
        case .scratchpadImage(let key, let maxPixelSize):
            guard workspaces.workspaces.contains(where: { $0.scratchpad.contains { $0.imageFiles.contains(key) } }),
                  let data = await TranscriptImage.display(at: ScratchpadEntry.directory.appending(path: key), maxPixelSize: maxPixelSize) else {
                return .failed(message: "That image is no longer available.")
            }
            return .image(data: data)
        case .refreshTasks:
            await integrations.refresh()
            return .done
        case .openedPullRequest(let taskID):
            tasksFeed.refreshPullRequests(taskID: taskID)
            return .done
        case .task(_, .openTerminal) where !connection.isLocal:
            return .hostOnly
        case .task(let id, .settle) where connection.caller == id:
            // An agent settling its own session finishes its turn first.
            guard integrations.threads.contains(where: { $0.id == id }) else { return .failed(message: "This task no longer exists.") }
            orchestrator.settleWhenDone(id)
            return .done
        case .task(let id, let action):
            switch action {
            case .settle, .restore: orchestrator.cancelSettling(id)
            default: break
            }
            let reply = await tasks.perform(action, onTask: id)
            // Reconcile optimistic client actions before acknowledging them.
            publishTasks(.tasks(tasksFeed.snapshot()))
            if case .rewind = action { feeds[.transcript(taskID: id)]?.refresh() }
            return reply
        case .compose(let provider, let workspaceID, let settings, let standalone):
            let reply = await tasks.compose(provider: provider, workspaceID: workspaceID, settings: settings)
            if case .task(let id) = reply, standalone != true, let device = connection.device, device.kind == .agent {
                orchestrator.started(id, by: device, caller: connection.caller)
            }
            return reply
        case .prompt(let taskID, let text, let images, let queueID):
            // Anyone else's prompt takes the session back up, as it would once settled.
            orchestrator.cancelSettling(taskID)
            let reply = await tasks.prompt(text, images: images, toTask: taskID, queueID: queueID, from: connection.caller)
            publishTasks(.tasks(tasksFeed.snapshot()))
            feeds[.transcript(taskID: taskID)]?.refresh()
            return reply
        case .skills(let taskID, let provider, let workspaceID):
            return await tasks.skills(forTask: taskID, provider: provider, workspaceID: workspaceID)
        case .interrupt(let taskID):
            return await tasks.interrupt(taskID, byPerson: connection.device?.kind != .agent, caller: connection.caller)
        case .addWorkspace(let paths):
            guard connection.isLocal else { return .hostOnly }
            let reply = WorkspaceService(workspaces: workspaces).add(paths: paths)
            // Clients list the project before the reply, so they open it.
            publishTasks(.tasks(tasksFeed.snapshot()))
            return reply
        case .workspace(let id, let action):
            guard let workspace = workspace(id) else { return .missingProject }
            let reply = WorkspaceService(workspaces: workspaces).perform(action, on: workspace, isLocal: connection.isLocal)
            if case .setFolders = action {
                // Clients see the folders and their status before the reply.
                publishTasks(.tasks(tasksFeed.snapshot()))
                await refreshGit(of: id)
            }
            return reply
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
        case .setRemoteAccess(let isEnabled):
            guard connection.isLocal else { return .hostOnly }
            isRemoteAccessEnabled = isEnabled
            return .done
        case .setHostName(let name):
            guard connection.isLocal else { return .hostOnly }
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            customHostName = trimmed.isEmpty ? nil : trimmed
            return .done
        case .setHostIcon(let icon):
            guard connection.isLocal else { return .hostOnly }
            hostIcon = icon
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
        case .commandOutput(let workspaceID, let commandID):
            guard let command = workspace(workspaceID)?.commands.first(where: { $0.id == commandID }) else { return nil }
            feed = CommandOutputFeed(workspaceID: workspaceID, command: command)
        case .backgroundSessionOutput(let workspaceID, let sessionID):
            guard workspace(workspaceID) != nil else { return nil }
            feed = BackgroundSessionOutputFeed(workspaceID: workspaceID, sessionID: sessionID, integrations: integrations)
        case .directory(let workspaceID, let path):
            guard let workspace = workspace(workspaceID), workspace.access.allows(path) else { return nil }
            feed = DirectoryFeed(workspaceID: workspaceID, path: path)
        case .file(let workspaceID, let path):
            guard let workspace = workspace(workspaceID), workspace.access.allows(path) else { return nil }
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
                for task in snapshot.tasksNeedingAttention(since: latestTasks) {
                    if let target = Self.attentionTarget(for: task, in: snapshot) { alertPhones(about: target) }
                }
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
        localListener.start(name: hostName)
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

    /// What a phone is alerted about, by the same rule as the Mac: sessions
    /// working for another alert as the session they're listed under, and they
    /// and sessions a paired agent started only when they need an
    /// answer. Side chats never alert.
    private static func attentionTarget(for task: WireTask, in snapshot: WireTasksSnapshot) -> WireTask? {
        guard task.origin != nil else { return task }
        guard task.status == .waiting, !task.isSideChat else { return nil }
        guard var ancestor = snapshot.listedAncestor(of: task) else { return task }
        ancestor.status = .waiting
        return ancestor
    }

    /// Alerts this Mac unless Atrium is showing the task already.
    private func alertMac(about thread: AgentThread) {
        guard NotificationRouting.shared.shouldNotifyMac(taskID: thread.id) else { return }
        // Alerts name a task's project, which a task relocated into a
        // linked worktree keeps, rather than the worktree folder.
        let workspace = workspaces.workspace(for: thread)
        NotificationRouting.shared.mac?.alert(
            taskID: thread.id,
            title: thread.title,
            projectName: workspace?.name ?? thread.projectName,
            needsInput: thread.status == .waiting,
            projectIcon: ProjectNotificationIcon.pngData(at: workspace?.customIconURL)
        )
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
            alertedDevices.insert(device.id)
        }
    }

    /// Atrium in front on one device means everything's been seen, so this
    /// Mac drops its alerts and badge, and each phone alerted since the last
    /// time is pushed to do the same. The device in front clears its own.
    private func clearAlerts(except device: UUID?) {
        NotificationRouting.shared.mac?.clearAlerts()
        let alerted = alertedDevices
        alertedDevices = []
        guard let listener else { return }
        for paired in pairing.devices where paired.id != device && alerted.contains(paired.id) {
            guard let push = paired.push else { continue }
            listener.push(RelayPushClear(token: push.token, environment: push.environment))
        }
    }
}

private extension HostReply {
    static let missingProject = HostReply.failed(message: "That project is no longer on this host.")
}

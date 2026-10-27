import CryptoKit
import Foundation
import Observation
import UIKit
import UserNotifications

/// The companion's connection to a paired host, through the relay with end-to-end
/// encryption, and the state it mirrors.
///
/// Views declare what they need with `follow(_:)`; the client subscribes while
/// any view follows a topic and resubscribes after reconnecting, so screens
/// never manage the connection themselves. Requests are async and resolve
/// with the host's reply.
@MainActor
@Observable
final class CompanionClient {
    private(set) var state: CompanionConnectionState = .idle
    private(set) var pairedHosts: [PairedHost] = []
    /// The host whose tasks are shown and that requests go to.
    private(set) var currentHost: PairedHost?
    private(set) var isPairing = false
    private(set) var pairingError: String?
    /// Changes each time a pairing succeeds, so a pairing sheet knows to close.
    private(set) var pairingCount = 0
    private var hostTasks: WireTasksSnapshot?
    private var taskUpdates: [OptimisticTaskUpdate] = []
    var tasks: WireTasksSnapshot? {
        guard var snapshot = hostTasks else { return nil }
        for update in taskUpdates { update.apply(to: &snapshot) }
        return snapshot
    }
    private(set) var gitStatuses: [UUID: WireGitStatus] = [:]
    private(set) var commands: [UUID: [WireCommand]] = [:]
    let conversations = ConversationStore()
    private(set) var transcripts: [String: [TranscriptMessage]] {
        get { conversations.transcripts }
        set { conversations.transcripts = newValue }
    }
    private(set) var pendingPrompts: [String: [PendingPrompt]] {
        get { conversations.pendingPrompts }
        set { conversations.pendingPrompts = newValue }
    }
    private(set) var tasksAwaitingAgent: [String: UUID] {
        get { conversations.tasksAwaitingAgent }
        set { conversations.tasksAwaitingAgent = newValue }
    }
    /// The latest failed action, shown as an alert.
    var actionError: String?
    /// Called as the transcript takes over showing a prompt sent from this
    /// phone, with the message that now shows it, so a send animation still
    /// running carries on in that message's row.
    @ObservationIgnored var onPendingPromptShown: ((PendingPrompt.ID, TranscriptMessage.ID) -> Void)?
    /// A task to navigate to, from a notification tap or a task just created.
    var pendingTaskID: String?
    private var notificationDestination: (hostID: String, taskID: String)?

    /// Never resolve against cached tasks or guess the sender of an old push.
    func openNotification(hostID: String?, taskID: String) {
        guard let hostID else {
            actionError = "This older notification doesn’t identify its Mac. Choose the Mac and task manually."
            return
        }
        guard let host = pairedHosts.first(where: { $0.id == hostID }) else {
            actionError = "The Mac that sent this notification is no longer paired."
            return
        }
        select(host)
        pendingTaskID = nil
        notificationDestination = (hostID, taskID)
        // An existing connection needs a new snapshot too. Reconnects resubscribe.
        if isConnected { subscribe(.tasks) }
        else { connectToPairedHost() }
    }

    private func resolveNotification(in snapshot: WireTasksSnapshot) {
        guard let destination = notificationDestination,
              destination.hostID == currentHost?.id else { return }
        notificationDestination = nil
        guard snapshot.tasks.contains(where: { $0.id == destination.taskID }) else {
            actionError = "This task is no longer available on this Mac."
            return
        }
        pendingTaskID = destination.taskID
    }
    /// New tasks opened on this phone, by draft ID. One stays after its first
    /// prompt until the task list shows the task the host created for it.
    private(set) var drafts: [String: TaskDraft] = [:]

    var isPaired: Bool { currentHost != nil }
    var pairedHostName: String? { currentHost?.displayName }
    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    /// Paired but without a live connection, so screens show cached state.
    var isReconnecting: Bool { isPaired && !isConnected }

    @ObservationIgnored private var activity = CompanionActivity(isActive: false, taskID: nil)
    @ObservationIgnored private var supportsActivity = false
    /// This install's APNs token, sent to each host so it can alert this phone.
    @ObservationIgnored private var pushRegistration: CompanionPushRegistration?
    @ObservationIgnored private var channel: (any CompanionChannel)?
    @ObservationIgnored private var pending: [UInt32: CheckedContinuation<CompanionReply, any Error>] = [:]
    @ObservationIgnored private var nextRequestID: UInt32 = 0
    @ObservationIgnored private var topicCounts: [CompanionTopic: Int] = [:]
    @ObservationIgnored private var icons: [String: Data] = [:]
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var failedAttempts = 0

    init() {
        pairedHosts = CompanionCredentials.pairedHosts
        currentHost = CompanionCredentials.currentHost
    }

    func start() {
        connectToPairedHost()
    }

    /// Pairs with a link from a host's QR code, scanned with the Camera app or pasted,
    /// and switches to that host.
    func pair(with link: CompanionPairingLink) {
        isPairing = true
        pairingError = nil
        connect(to: PairedHost(link: link), authentication: .pair(secret: link.secret))
    }

    func handle(_ url: URL) {
        guard let link = CompanionPairingLink(url: url) else { return }
        pair(with: link)
    }

    func select(_ host: PairedHost) {
        guard host.id != currentHost?.id else { return }
        notificationDestination = nil
        pendingTaskID = nil
        CompanionCredentials.select(host)
        currentHost = host
        closeChannel()
        clearMirroredState()
        failedAttempts = 0
        connectToPairedHost()
    }

    /// Forgets a host. Pairing it again needs a fresh QR code from its Settings.
    func forget(_ host: PairedHost) {
        CompanionCredentials.forget(host)
        pairedHosts = CompanionCredentials.pairedHosts
        guard host.id == currentHost?.id else { return }
        notificationDestination = nil
        currentHost = nil
        closeChannel()
        clearMirroredState()
        state = .idle
        if let next = CompanionCredentials.currentHost { select(next) }
    }

    /// Names a host on this phone only; an empty name goes back to the host's own.
    func rename(_ host: PairedHost, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        CompanionCredentials.rename(host, to: name.isEmpty ? nil : name)
        pairedHosts = CompanionCredentials.pairedHosts
        if host.id == currentHost?.id { currentHost = pairedHosts.first { $0.id == host.id } }
    }

    private func clearMirroredState() {
        hostTasks = nil
        taskUpdates.removeAll()
        gitStatuses = [:]
        commands = [:]
        conversations.reset()
        drafts = [:]
        icons = [:]
    }

    /// Tries the host again now instead of waiting out the retry delay.
    func retryNow() {
        guard !isConnected else { return }
        closeChannel()
        failedAttempts = 0
        connectToPairedHost()
    }

    func sceneDidBecomeActive() {
        connectToPairedHost()
    }

    var visibleTaskID: String? { activity.isActive ? activity.taskID : nil }

    func setSceneActive(_ active: Bool) {
        activity.isActive = active
        publishActivity()
        if active { sceneDidBecomeActive() }
    }

    func setVisibleTask(_ taskID: String?) {
        guard activity.taskID != taskID else { return }
        activity.taskID = taskID
        publishActivity()
    }

    func clearVisibleTask(_ taskID: String) {
        if activity.taskID == taskID { setVisibleTask(nil) }
    }

    private func publishActivity() {
        guard isConnected, supportsActivity else { return }
        let snapshot = activity
        Task { try? await request(.activity(snapshot)) }
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
        let update = OptimisticTaskUpdate(request)
        if let update { taskUpdates.append(update) }
        defer {
            if let update { taskUpdates.removeAll { $0.id == update.id } }
        }
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

    // MARK: - Push notifications

    /// Records this install's APNs token and gives it to the connected host.
    func didRegisterForPush(token: Data) {
        #if DEBUG
        let environment = CompanionPushRegistration.Environment.sandbox
        #else
        let environment = CompanionPushRegistration.Environment.production
        #endif
        let registration = CompanionPushRegistration(
            token: token.map { ($0 < 16 ? "0" : "") + String($0, radix: 16) }.joined(),
            environment: environment
        )
        pushRegistration = registration
        if isConnected { send(.registerPush(registration)) }
    }

    /// Asks once to show alerts, then registers with APNs, which answers
    /// through `didRegisterForPush(token:)` on every launch.
    private func registerForPush() {
        if let pushRegistration { send(.registerPush(pushRegistration)) }
        Task {
            let center = UNUserNotificationCenter.current()
            guard (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) == true else { return }
            UIApplication.shared.registerForRemoteNotifications()
        }
    }

    // MARK: - Prompts

    /// Sends a prompt to a task's agent, showing it in the timeline at once.
    /// A failed send stays there with a retry button instead of an alert.
    /// - Returns: The ID of the prompt's row in the timeline.
    @discardableResult
    func sendPrompt(_ text: String, images: [Data] = [], to taskID: String) -> PendingPrompt.ID {
        let prompt = conversations.enqueue(text, images: images, to: taskID)
        deliver(prompt.id, to: taskID)
        return prompt.id
    }

    func retryPrompt(_ id: UUID, in taskID: String) {
        conversations.prepareRetry(id, in: taskID)
        deliver(id, to: taskID)
    }

    private func deliver(_ id: UUID, to taskID: String) {
        guard pendingPrompts[taskID]?.contains(where: { $0.id == id }) == true else { return }
        tasksAwaitingAgent[taskID] = id
        // A draft's prompts wait for the host to create its task.
        if let draft = drafts[taskID] {
            if !draft.isCreating, draft.taskID == nil { createTask(from: draft) }
            return
        }
        conversations.deliver(id, to: taskID, using: self) { [weak self] in
            self?.task(taskID)?.status
        }
    }

    private func markPendingPromptFailed(_ id: UUID, in taskID: String) {
        conversations.markFailed(id, in: taskID)
    }

    private func settleTasksAwaitingAgent() {
        for taskID in tasksAwaitingAgent.keys {
            if let status = task(taskID)?.status {
                conversations.noteStatus(status, for: taskID)
            } else if draftTask(taskID) == nil {
                tasksAwaitingAgent[taskID] = nil
            }
        }
    }

    private func dropOverduePrompts() {
        for taskID in pendingPrompts.keys {
            if let status = task(taskID)?.status { conversations.noteStatus(status, for: taskID) }
        }
    }

    private func reconcilePendingPrompts(for taskID: String) {
        for confirmation in conversations.reconcile(taskID: taskID) {
            onPendingPromptShown?(confirmation.promptID, confirmation.messageID)
        }
    }

    // MARK: - Drafts

    /// The agent a new task starts with: the one this phone last started a
    /// task with, while the host has it enabled, else the host's first.
    var defaultProvider: AgentProvider? {
        let enabled = tasks?.providers.filter(\.isEnabled).map(\.provider) ?? []
        let last = UserDefaults.standard.string(forKey: Self.lastProviderKey).flatMap(AgentProvider.init(rawValue:))
        return enabled.first { $0 == last } ?? enabled.first
    }

    private static let lastProviderKey = "newTaskProvider"

    /// Opens a new task in a project. The host creates it once its first
    /// prompt is sent.
    /// - Returns: The draft's ID, or nil while the host has no agent enabled.
    func openDraft(in workspaceID: UUID, provider: AgentProvider? = nil) -> String? {
        guard let provider = provider ?? defaultProvider else { return nil }
        let draft = TaskDraft(workspaceID: workspaceID, provider: provider)
        drafts[draft.id] = draft
        // A new task has no messages to load.
        transcripts[draft.id] = []
        return draft.id
    }

    /// Picks the agent a draft's task is created with, until its first prompt is sent.
    func setProvider(_ provider: AgentProvider, ofDraft id: String) {
        guard let draft = drafts[id], !draft.isCreating, draft.taskID == nil else { return }
        drafts[id]?.provider = provider
    }

    /// Forgets a draft another task has opened in place of, unless its first
    /// prompt has been sent, which leaves nothing behind on the host.
    func closeDraft(_ id: String) {
        guard let draft = drafts[id], !draft.isCreating, draft.taskID == nil else { return }
        forgetDraft(id)
    }

    private func forgetDraft(_ id: String) {
        drafts[id] = nil
        conversations.remove(id)
    }

    /// What a draft shows in place of its task, by the draft's ID or, once
    /// the host has created the task, by the task's own until the task list
    /// shows it. It takes the ID of the task once there is one.
    func draftTask(_ id: String) -> WireTask? {
        guard let draft = drafts[id] ?? drafts.values.first(where: { $0.taskID == id }) else { return nil }
        let workspace = workspace(draft.workspaceID)
        return WireTask(
            id: draft.taskID ?? draft.id,
            title: "New Task",
            provider: draft.provider,
            status: .idle,
            projectName: workspace?.name ?? "",
            directory: workspace?.directory ?? "",
            workspaceID: draft.workspaceID,
            updatedAt: draft.createdAt,
            hasUnreadResult: false,
            isSettled: false,
            supportsDeletion: false,
            actions: .prompt
        )
    }

    /// Has the host create a draft's task for its first prompt. Prompts sent
    /// meanwhile wait with it, and all fail together if the host can't.
    private func createTask(from draft: TaskDraft) {
        drafts[draft.id]?.isCreating = true
        Task {
            do {
                guard case .task(let taskID) = try await request(.compose(provider: draft.provider, workspaceID: draft.workspaceID)) else {
                    throw CompanionClientError.unexpectedReply
                }
                didCreateTask(taskID, from: draft.id)
            } catch {
                guard drafts[draft.id] != nil else { return }
                drafts[draft.id]?.isCreating = false
                // The host's reason, such as the agent having been turned off,
                // says what to change before retrying.
                if case CompanionClientError.rejected(let message) = error { actionError = message }
                for prompt in pendingPrompts[draft.id] ?? [] where prompt.state == .sending {
                    markPendingPromptFailed(prompt.id, in: draft.id)
                }
                tasksAwaitingAgent[draft.id] = nil
            }
        }
    }

    /// Moves a draft's prompts to the task the host created for it and
    /// delivers them, opening the task in the draft's place if it's on screen.
    private func didCreateTask(_ taskID: String, from draftID: String) {
        guard let draft = drafts[draftID] else { return }
        drafts[draftID]?.isCreating = false
        drafts[draftID]?.taskID = taskID
        UserDefaults.standard.set(draft.provider.rawValue, forKey: Self.lastProviderKey)
        if transcripts[taskID] == nil { transcripts[taskID] = [] }
        let prompts = pendingPrompts.removeValue(forKey: draftID) ?? []
        pendingPrompts[taskID, default: []].append(contentsOf: prompts)
        tasksAwaitingAgent[draftID] = nil
        if activity.taskID == draftID { pendingTaskID = taskID }
        for prompt in prompts where prompt.state == .sending {
            deliver(prompt.id, to: taskID)
        }
    }

    /// Drops drafts whose task the task list now shows, once they're off screen.
    private func dropListedDrafts() {
        for (id, draft) in drafts {
            guard let taskID = draft.taskID, task(taskID) != nil, activity.taskID != id else { continue }
            drafts[id] = nil
            transcripts[id] = nil
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

    /// The models a provider's tasks can switch to, as the host lists them.
    func models(for provider: AgentProvider) -> [AgentModel] {
        tasks?.providers.first { $0.provider == provider }?.models ?? []
    }

    // MARK: - Connection

    private enum Authentication {
        case pair(secret: String)
        case token(String)
    }

    private func connectToPairedHost() {
        guard channel == nil, reconnectTask == nil, let currentHost, let token = CompanionCredentials.token(for: currentHost) else { return }
        connect(to: currentHost, authentication: .token(token))
    }

    /// Opens an encrypted channel through the relay, bound to the host's key from its QR code.
    private func connect(to host: PairedHost, authentication: Authentication) {
        closeChannel()
        state = .connecting(hostName: host.displayName)
        guard let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: host.publicKey) else {
            state = .failed("This pairing QR code isn’t valid.")
            return
        }
        let channel = NoiseChannel(
            inner: RelayClientChannel(macID: host.hostID),
            role: .initiator(responderStatic: key),
            prologue: CompanionPairingLink.prologue(macID: host.hostID)
        )
        self.channel = channel
        channel.onReady = { [weak self, weak channel] in
            Task {
                guard let self, let channel, self.channel === channel else { return }
                await self.authenticate(authentication, host: host)
            }
        }
        channel.onMessage = { [weak self, weak channel] data in
            guard let self, let channel, self.channel === channel else { return }
            self.receive(data)
        }
        channel.onClose = { [weak self, weak channel] reason in
            guard let self, let channel, self.channel === channel else { return }
            self.channelDidClose(reason)
        }
        channel.start()
    }

    private func authenticate(_ authentication: Authentication, host: PairedHost) async {
        guard let authenticatingChannel = channel else { return }
        do {
            switch authentication {
            case .pair(let secret):
                guard case .paired(let token) = try await request(.pair(secret: secret, device: CompanionCredentials.device)) else {
                    throw CompanionClientError.unexpectedReply
                }
                guard channel === authenticatingChannel else { return }
                CompanionCredentials.save(host, token: token)
                pairedHosts = CompanionCredentials.pairedHosts
                if host.id != currentHost?.id { clearMirroredState() }
                currentHost = CompanionCredentials.currentHost
                isPairing = false
                pairingCount += 1
            case .token(let token):
                _ = try await request(.authenticate(token: token, deviceID: CompanionCredentials.device.id))
            }
            guard channel === authenticatingChannel else { return }
            state = .connected(hostName: host.displayName)
            failedAttempts = 0
            publishActivity()
            registerForPush()
            for topic in topicCounts.keys { subscribe(topic) }
        } catch {
            guard channel === authenticatingChannel else { return }
            switch (authentication, error) {
            case (.token, CompanionClientError.rejected):
                // The host revoked this phone; staying paired would retry forever.
                forget(host)
                state = .failed(error.localizedDescription)
            case (.token, _):
                channelDidClose(error.localizedDescription)
            case (.pair, _):
                // Go back to the host in use, if any, and report why pairing failed.
                closeChannel()
                isPairing = false
                pairingError = error.localizedDescription
                state = .idle
                connectToPairedHost()
            }
        }
    }

    private func channelDidClose(_ reason: String?) {
        closeChannel()
        if isPairing {
            // The new host couldn't be reached; stay with the one in use.
            isPairing = false
            pairingError = reason ?? CompanionClientError.disconnected.localizedDescription
            state = .idle
            connectToPairedHost()
            return
        }
        state = .failed(reason ?? CompanionClientError.disconnected.localizedDescription)
        guard isPaired else { return }
        // Back off while the host stays unreachable, up to half a minute between tries.
        failedAttempts += 1
        let delay = Duration.seconds(min(2 << min(failedAttempts - 1, 4), 30))
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            self?.reconnectTask = nil
            self?.connectToPairedHost()
        }
    }

    private func closeChannel() {
        reconnectTask?.cancel()
        reconnectTask = nil
        let channel = channel
        self.channel = nil
        supportsActivity = false
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
        case .hello(_, let protocolVersion):
            supportsActivity = protocolVersion >= 5
        case .tasks(let snapshot):
            hostTasks = snapshot
            resolveNotification(in: snapshot)
            dropListedDrafts()
            settleTasksAwaitingAgent()
            dropOverduePrompts()
        case .tasksChanged(let delta):
            guard var snapshot = hostTasks else { return }
            snapshot.apply(delta)
            hostTasks = snapshot
            dropListedDrafts()
            settleTasksAwaitingAgent()
            dropOverduePrompts()
        case .git(let workspaceID, let status):
            gitStatuses[workspaceID] = status
        case .commands(let workspaceID, let commands):
            self.commands[workspaceID] = commands
        case .transcript(let taskID, let messages):
            transcripts[taskID] = messages
            reconcilePendingPrompts(for: taskID)
        case .transcriptChanged(let taskID, let delta):
            transcripts[taskID, default: []].apply(delta)
            reconcilePendingPrompts(for: taskID)
        }
    }
}


extension CompanionClient: ConversationTransport {
    func deliverPrompt(_ prompt: PendingPrompt, to taskID: String) async throws {
        _ = try await request(.prompt(taskID: taskID, text: prompt.text, images: prompt.images))
    }

    func interruptConversation(taskID: String) async throws {
        _ = try await request(.interrupt(taskID: taskID))
    }
}

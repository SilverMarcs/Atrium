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
    private(set) var transcripts: [String: [TranscriptMessage]] = [:]
    /// Prompts sent from this phone that each task's transcript doesn't show yet.
    private(set) var pendingPrompts: [String: [PendingPrompt]] = [:]
    /// Tasks just sent a prompt whose agent hasn't reported working yet, by the
    /// latest prompt's ID, so their timelines show it working right away.
    private(set) var tasksAwaitingAgent: [String: UUID] = [:]
    /// The latest failed action, shown as an alert.
    var actionError: String?
    /// A task to navigate to, from a notification tap or a task just created.
    var pendingTaskID: String?

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
        transcripts = [:]
        pendingPrompts = [:]
        tasksAwaitingAgent = [:]
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
    func sendPrompt(_ text: String, images: [Data] = [], to taskID: String) {
        let prompt = PendingPrompt(
            text: text,
            images: images,
            anchorUserMessageID: newestUserMessageID(in: taskID),
            expectedUserMessagesAfterAnchor: nextExpectedUserMessageCount(for: taskID)
        )
        pendingPrompts[taskID, default: []].append(prompt)
        deliver(prompt.id, to: taskID)
    }

    func retryPrompt(_ id: UUID, in taskID: String) {
        let anchor = newestUserMessageID(in: taskID)
        let expected = nextExpectedUserMessageCount(for: taskID)
        updatePendingPrompt(id, in: taskID) {
            $0.state = .sending
            $0.anchorUserMessageID = anchor
            $0.expectedUserMessagesAfterAnchor = expected
        }
        deliver(id, to: taskID)
    }

    private func deliver(_ id: UUID, to taskID: String) {
        guard let prompt = pendingPrompts[taskID]?.first(where: { $0.id == id }) else { return }
        tasksAwaitingAgent[taskID] = id
        Task {
            do {
                _ = try await request(.prompt(taskID: taskID, text: prompt.text, images: prompt.images))
                updatePendingPrompt(id, in: taskID) { $0.state = .sent }
                // An agent whose transcript never shows the prompt, or that
                // never reports working, mustn't leave either pending forever.
                try? await Task.sleep(for: .seconds(20))
                if task(taskID)?.status == .processing {
                    // A working agent takes a prompt sent mid-turn only between
                    // steps, so it stays until the agent stops.
                    updatePendingPrompt(id, in: taskID) { $0.isOverdue = true }
                } else {
                    pendingPrompts[taskID]?.removeAll { $0.id == id && $0.state == .sent }
                }
                stopAwaitingAgent(for: taskID, after: id)
            } catch {
                markPendingPromptFailed(id, in: taskID)
                stopAwaitingAgent(for: taskID, after: id)
            }
        }
    }

    private func updatePendingPrompt(_ id: UUID, in taskID: String, _ update: (inout PendingPrompt) -> Void) {
        guard var prompts = pendingPrompts[taskID],
              let index = prompts.firstIndex(where: { $0.id == id }) else { return }
        update(&prompts[index])
        pendingPrompts[taskID] = prompts
    }

    /// A failed prompt never reaches the transcript, so prompts sent after it
    /// expect one user message fewer.
    private func markPendingPromptFailed(_ id: UUID, in taskID: String) {
        guard var prompts = pendingPrompts[taskID],
              let index = prompts.firstIndex(where: { $0.id == id }) else { return }
        prompts[index].state = .failed
        for later in prompts.indices.dropFirst(index + 1) where prompts[later].state != .failed {
            prompts[later].expectedUserMessagesAfterAnchor -= 1
        }
        pendingPrompts[taskID] = prompts
    }

    /// Stops showing the task working for a prompt, unless a later one has
    /// taken over.
    private func stopAwaitingAgent(for taskID: String, after id: UUID) {
        if tasksAwaitingAgent[taskID] == id {
            tasksAwaitingAgent[taskID] = nil
        }
    }

    /// Hands over to the agent's own status once it reports working or
    /// needing input.
    private func settleTasksAwaitingAgent() {
        guard !tasksAwaitingAgent.isEmpty else { return }
        tasksAwaitingAgent = tasksAwaitingAgent.filter { taskID, _ in
            guard let status = task(taskID)?.status else { return false }
            return status != .processing && status != .waiting
        }
    }

    /// Drops overdue prompts once their agent stops without showing them.
    private func dropOverduePrompts() {
        for (taskID, prompts) in pendingPrompts where prompts.contains(where: \.isOverdue) {
            guard task(taskID)?.status != .processing else { continue }
            pendingPrompts[taskID]?.removeAll { $0.isOverdue && $0.state == .sent }
            if pendingPrompts[taskID]?.isEmpty == true { pendingPrompts[taskID] = nil }
        }
    }

    /// The user messages the transcript holds after its newest one once it
    /// shows the next prompt: one past what's already on its way.
    private func nextExpectedUserMessageCount(for taskID: String) -> Int {
        pendingPrompts[taskID, default: []].filter { $0.state != .failed }.count + 1
    }

    private func newestUserMessageID(in taskID: String) -> String? {
        transcripts[taskID]?.last { $0.role == .user }?.id
    }

    /// User messages after the anchor. An anchor that has dropped out of the
    /// transcript's window is older than everything left in it.
    private func userMessageCount(in taskID: String, after anchorID: String?) -> Int {
        let messages = transcripts[taskID, default: []]
        let start = anchorID.flatMap { id in messages.firstIndex { $0.id == id } }.map { $0 + 1 } ?? 0
        return messages[start...].count { $0.role == .user }
    }

    /// Drops prompts the transcript now shows.
    private func reconcilePendingPrompts(for taskID: String) {
        guard let prompts = pendingPrompts[taskID] else { return }
        let shown = prompts.filter {
            $0.state != .failed
                && $0.expectedUserMessagesAfterAnchor <= userMessageCount(in: taskID, after: $0.anchorUserMessageID)
        }
        guard !shown.isEmpty else { return }
        pendingPrompts[taskID]?.removeAll { prompt in shown.contains { $0.id == prompt.id } }
        if pendingPrompts[taskID]?.isEmpty == true { pendingPrompts[taskID] = nil }
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
        channel.onReady = { [weak self] in
            Task { await self?.authenticate(authentication, host: host) }
        }
        channel.onMessage = { [weak self] data in self?.receive(data) }
        channel.onClose = { [weak self, weak channel] reason in
            guard let self, let channel, self.channel === channel else { return }
            self.channelDidClose(reason)
        }
        channel.start()
    }

    private func authenticate(_ authentication: Authentication, host: PairedHost) async {
        do {
            switch authentication {
            case .pair(let secret):
                guard case .paired(let token) = try await request(.pair(secret: secret, device: CompanionCredentials.device)) else {
                    throw CompanionClientError.unexpectedReply
                }
                CompanionCredentials.save(host, token: token)
                pairedHosts = CompanionCredentials.pairedHosts
                if host.id != currentHost?.id { clearMirroredState() }
                currentHost = CompanionCredentials.currentHost
                isPairing = false
                pairingCount += 1
            case .token(let token):
                _ = try await request(.authenticate(token: token, deviceID: CompanionCredentials.device.id))
            }
            state = .connected(hostName: host.displayName)
            failedAttempts = 0
            publishActivity()
            registerForPush()
            for topic in topicCounts.keys { subscribe(topic) }
        } catch {
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
            settleTasksAwaitingAgent()
            dropOverduePrompts()
        case .tasksChanged(let delta):
            guard var snapshot = hostTasks else { return }
            snapshot.apply(delta)
            hostTasks = snapshot
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

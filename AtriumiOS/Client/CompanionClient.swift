import CryptoKit
import Foundation
import Observation

/// The companion's connection to a paired Mac, through the relay with end-to-end
/// encryption, and the state it mirrors.
///
/// Views declare what they need with `follow(_:)`; the client subscribes while
/// any view follows a topic and resubscribes after reconnecting, so screens
/// never manage the connection themselves. Requests are async and resolve
/// with the Mac's reply.
@MainActor
@Observable
final class CompanionClient {
    private(set) var state: CompanionConnectionState = .idle
    private(set) var pairedMacs: [PairedMac] = []
    /// The Mac whose tasks are shown and that requests go to.
    private(set) var currentMac: PairedMac?
    private(set) var isPairing = false
    private(set) var pairingError: String?
    /// Changes each time a pairing succeeds, so a pairing sheet knows to close.
    private(set) var pairingCount = 0
    private(set) var tasks: WireTasksSnapshot?
    private(set) var gitStatuses: [UUID: WireGitStatus] = [:]
    private(set) var commands: [UUID: [WireCommand]] = [:]
    private(set) var transcripts: [String: [TranscriptMessage]] = [:]
    /// The latest failed action, shown as an alert.
    var actionError: String?
    /// A task to navigate to, from a notification tap or a task just created.
    var pendingTaskID: String?

    var isPaired: Bool { currentMac != nil }
    var pairedHostName: String? { currentMac?.displayName }
    var isConnected: Bool {
        if case .connected = state { return true }
        return false
    }

    /// Paired but without a live connection, so screens show cached state.
    var isReconnecting: Bool { isPaired && !isConnected }

    @ObservationIgnored private let notifier = TaskAttentionNotifier()
    @ObservationIgnored private var channel: (any CompanionChannel)?
    @ObservationIgnored private var pending: [UInt32: CheckedContinuation<CompanionReply, any Error>] = [:]
    @ObservationIgnored private var nextRequestID: UInt32 = 0
    @ObservationIgnored private var topicCounts: [CompanionTopic: Int] = [:]
    @ObservationIgnored private var icons: [String: Data] = [:]
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var failedAttempts = 0

    init() {
        pairedMacs = CompanionCredentials.pairedMacs
        currentMac = CompanionCredentials.currentMac
    }

    func start() {
        connectToPairedMac()
    }

    /// Pairs with a link from a Mac's QR code, scanned with the Camera app or pasted,
    /// and switches to that Mac.
    func pair(with link: CompanionPairingLink) {
        isPairing = true
        pairingError = nil
        connect(to: PairedMac(link: link), authentication: .pair(secret: link.secret))
    }

    func handle(_ url: URL) {
        guard let link = CompanionPairingLink(url: url) else { return }
        pair(with: link)
    }

    func select(_ mac: PairedMac) {
        guard mac.id != currentMac?.id else { return }
        CompanionCredentials.select(mac)
        currentMac = mac
        closeChannel()
        clearMirroredState()
        failedAttempts = 0
        connectToPairedMac()
    }

    /// Forgets a Mac. Pairing it again needs a fresh QR code from its Settings.
    func forget(_ mac: PairedMac) {
        CompanionCredentials.forget(mac)
        pairedMacs = CompanionCredentials.pairedMacs
        guard mac.id == currentMac?.id else { return }
        currentMac = nil
        closeChannel()
        clearMirroredState()
        state = .idle
        if let next = CompanionCredentials.currentMac { select(next) }
    }

    /// Names a Mac on this phone only; an empty name goes back to the Mac's own.
    func rename(_ mac: PairedMac, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        CompanionCredentials.rename(mac, to: name.isEmpty ? nil : name)
        pairedMacs = CompanionCredentials.pairedMacs
        if mac.id == currentMac?.id { currentMac = pairedMacs.first { $0.id == mac.id } }
    }

    private func clearMirroredState() {
        tasks = nil
        gitStatuses = [:]
        commands = [:]
        transcripts = [:]
        icons = [:]
    }

    /// Tries the Mac again now instead of waiting out the retry delay.
    func retryNow() {
        guard !isConnected else { return }
        closeChannel()
        failedAttempts = 0
        connectToPairedMac()
    }

    func sceneDidBecomeActive() {
        connectToPairedMac()
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
        case pair(secret: String)
        case token(String)
    }

    private func connectToPairedMac() {
        guard channel == nil, reconnectTask == nil, let currentMac, let token = CompanionCredentials.token(for: currentMac) else { return }
        connect(to: currentMac, authentication: .token(token))
    }

    /// Opens an encrypted channel through the relay, bound to the Mac's key from its QR code.
    private func connect(to mac: PairedMac, authentication: Authentication) {
        closeChannel()
        state = .connecting(hostName: mac.displayName)
        guard let key = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: mac.publicKey) else {
            state = .failed("This pairing QR code isn’t valid.")
            return
        }
        let channel = NoiseChannel(
            inner: RelayClientChannel(relay: mac.relay, macID: mac.macID),
            role: .initiator(responderStatic: key),
            prologue: CompanionPairingLink.prologue(macID: mac.macID)
        )
        self.channel = channel
        channel.onReady = { [weak self] in
            Task { await self?.authenticate(authentication, mac: mac) }
        }
        channel.onMessage = { [weak self] data in self?.receive(data) }
        channel.onClose = { [weak self, weak channel] reason in
            guard let self, let channel, self.channel === channel else { return }
            self.channelDidClose(reason)
        }
        channel.start()
    }

    private func authenticate(_ authentication: Authentication, mac: PairedMac) async {
        do {
            switch authentication {
            case .pair(let secret):
                guard case .paired(let token) = try await request(.pair(secret: secret, device: CompanionCredentials.device)) else {
                    throw CompanionClientError.unexpectedReply
                }
                CompanionCredentials.save(mac, token: token)
                pairedMacs = CompanionCredentials.pairedMacs
                if mac.id != currentMac?.id { clearMirroredState() }
                currentMac = CompanionCredentials.currentMac
                isPairing = false
                pairingCount += 1
            case .token(let token):
                _ = try await request(.authenticate(token: token, deviceID: CompanionCredentials.device.id))
            }
            state = .connected(hostName: mac.displayName)
            failedAttempts = 0
            notifier.requestAuthorization()
            for topic in topicCounts.keys { subscribe(topic) }
        } catch {
            switch (authentication, error) {
            case (.token, CompanionClientError.rejected):
                // The Mac revoked this phone; staying paired would retry forever.
                forget(mac)
                state = .failed(error.localizedDescription)
            case (.token, _):
                channelDidClose(error.localizedDescription)
            case (.pair, _):
                // Go back to the Mac in use, if any, and report why pairing failed.
                closeChannel()
                isPairing = false
                pairingError = error.localizedDescription
                state = .idle
                connectToPairedMac()
            }
        }
    }

    private func channelDidClose(_ reason: String?) {
        closeChannel()
        if isPairing {
            // The new Mac couldn't be reached; stay with the one in use.
            isPairing = false
            pairingError = reason ?? CompanionClientError.disconnected.localizedDescription
            state = .idle
            connectToPairedMac()
            return
        }
        state = .failed(reason ?? CompanionClientError.disconnected.localizedDescription)
        guard isPaired else { return }
        // Back off while the Mac stays unreachable, up to half a minute between tries.
        failedAttempts += 1
        let delay = Duration.seconds(min(2 << min(failedAttempts - 1, 4), 30))
        reconnectTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            self?.reconnectTask = nil
            self?.connectToPairedMac()
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
        case .transcript(let taskID, let messages):
            transcripts[taskID] = messages
        case .transcriptChanged(let taskID, let delta):
            transcripts[taskID, default: []].apply(delta)
        }
    }
}
